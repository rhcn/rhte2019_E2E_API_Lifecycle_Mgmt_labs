new_guid=`echo $HOSTNAME | cut -d'.' -f 1 | cut -d'-' -f 2`
stale_guid=`cat $HOME/guid`
api_control_plane_project=3scale-mt-api0
openbanking_dev_gw_project=openbanking-dev-gw
openbanking_prod_gw_project=openbanking-prod-gw
openbanking_nexus_project=openbanking-nexus
new_threescale_superdomain=apps-$new_guid.generic.opentlc.com


# 22 August 2019; JA Bride
# The following error is occuring:
#
#   failed to create ACME certificate: 429 urn:acme:error:rateLimited: Error creating new cert :: too many certificates already issued for: opentlc.com: see https://letsencrypt.org/docs/rate-limits/
enableLetsEncryptCertsOnRoutes() {
    oc delete project prod-letsencrypt
    oc new-project prod-letsencrypt
    oc create -fhttps://raw.githubusercontent.com/gpe-mw-training/openshift-acme/master/deploy/letsencrypt-live/cluster-wide/{clusterrole,serviceaccount,imagestream,deployment}.yaml -n prod-letsencrypt
    oc adm policy add-cluster-role-to-user openshift-acme -z openshift-acme

    echo -en "metadata:\n  annotations:\n    kubernetes.io/tls-acme: \"true\"" > /tmp/route-tls-patch.yml
    oc patch route system-master --type merge --patch "$(cat /tmp/route-tls-patch.yml)" -n $api_control_plane_project
    oc patch route system-developer --type merge --patch "$(cat /tmp/route-tls-patch.yml)" -n $api_control_plane_project
    oc patch route system-provider-admin --type merge --patch "$(cat /tmp/route-tls-patch.yml)" -n $api_control_plane_project
    oc patch route nexus --type merge --patch "$(cat /tmp/route-tls-patch.yml)" -n $openbanking_nexus_project
    oc patch route openbanking-dev-developer --type merge --patch "$(cat /tmp/route-tls-patch.yml)" -n $api_control_plane_project
    oc patch route openbanking-dev-provider --type merge --patch "$(cat /tmp/route-tls-patch.yml)" -n $api_control_plane_project
    oc patch route openbanking-prod-developer --type merge --patch "$(cat /tmp/route-tls-patch.yml)" -n $api_control_plane_project
    oc patch route openbanking-prod-provider --type merge --patch "$(cat /tmp/route-tls-patch.yml)" -n $api_control_plane_project
}

refreshControlPlane() {
  # Switch to namespace of API Manager Control Plane
  oc project $api_control_plane_project


  echo -en "\nwill update the following stale guid in the API Manager from: $stale_guid to $new_guid\n\n"


  ####  Update all references to old GUID in system-mysql database #####

  echo -en "stale URLs in system-mysql .... \n"
  oc exec `oc get pod | grep "system-mysql" | awk '{print $1}'` \
     -- bash -c 'mysql -u root system -e "select id, domain, self_domain from accounts where domain is not null"'

  # update self_domain in accounts (so as to fix existing API tenants )
  oc exec `oc get pod | grep "system-mysql" | awk '{print $1}'` \
     -- bash -c \
     'mysql -u root system -e "update accounts set self_domain = replace(self_domain, \"'$stale_guid'\", \"'$new_guid'\") where       self_domain like \"%'$stale_guid'%\";"'

  # update domain (so as to fix existing API tenants)
  oc exec `oc get pod | grep "system-mysql" | awk '{print $1}'` \
     -- bash -c \
     'mysql -u root system -e "update accounts set domain = replace(domain, \"'$stale_guid'\", \"'$new_guid'\") where domain like   \"%'$stale_guid'%\";"'

  echo -en "\n\nupdated URLs in system-mysql .... \n"
  oc exec `oc get pod | grep "system-mysql" | awk '{print $1}'` \
     -- bash -c 'mysql -u root system -e "select id, domain, self_domain from accounts where domain is not null"'

  echo -en "\n\n"


  ########   Patch backend-listener secret #######
  b64_url=`echo https://backend-t1-$api_control_plane_project.$new_threescale_superdomain | base64 -w 0`
  oc patch secret backend-listener -p "{\"data\":{\"route_endpoint\":\"$b64_url\"} }"

}

refreshDataPlane() {

  # Enabled wildcard routes
  oc set env dc/router ROUTER_ALLOW_WILDCARD_ROUTES=true -n default

  oldTPE=`oc get deploy prod-apicast -o json -n $openbanking_dev_gw_project | /usr/local/bin/jq .spec.template.spec.containers[0].env[0].value`
  newTPE=`echo $oldTPE | sed "s/apps-$stale_guid/apps-$new_guid/" | sed "s/\"//g"`
  oldAPIHOST=`oc get deploy wc-router -o json -n $openbanking_dev_gw_project | /usr/local/bin/jq .spec.template.spec.containers[0].env[0].value`
  newAPIHOST=`echo $oldAPIHOST | sed "s/apps-$stale_guid/apps-$new_guid/" | sed "s/\"//g"`

  # update dev_gw
  oc patch deploy prod-apicast -n $openbanking_dev_gw_project -p '{"spec":{"template":{"spec":{"containers":[{"name":"prod-apicast","env":[{"name":"THREESCALE_PORTAL_ENDPOINT","value":"'$newTPE'"}]}]}}}}'
  oc patch deploy stage-apicast -n $openbanking_dev_gw_project -p '{"spec":{"template":{"spec":{"containers":[{"name":"stage-apicast","env":[{"name":"THREESCALE_PORTAL_ENDPOINT","value":"'$newTPE'"}]}]}}}}'
  oc patch deploy wc-router -n $openbanking_dev_gw_project -p '{"spec":{"template":{"spec":{"containers":[{"name":"wc-router","env":  [{"name":"API_HOST","value":"'$newAPIHOST'"}]}]}}}}'

  oc delete route wc-router -n $openbanking_dev_gw_project
  oc create route edge wc-router --service=wc-router --wildcard-policy=Subdomain --hostname=wc-router.$openbanking_dev_gw_project.$new_threescale_superdomain -n $openbanking_dev_gw_project

    # update prod_gw
  oldTPE=`oc get deploy prod-apicast -o json -n $openbanking_prod_gw_project | /usr/local/bin/jq .spec.template.spec.containers[0].env[0].value`
  newTPE=`echo $oldTPE | sed "s/apps-$stale_guid/apps-$new_guid/" | sed "s/openbanking-dev-admin/openbanking-prod-admin/" | sed "s/\"//g"`
  oldAPIHOST=`oc get deploy wc-router -o json -n $openbanking_prod_gw_project | /usr/local/bin/jq .spec.template.spec.containers[0].env[0].value`
  newAPIHOST=`echo $oldAPIHOST | sed "s/apps-$stale_guid/apps-$new_guid/" | sed "s/\"//g"`

  oc patch deploy prod-apicast -n $openbanking_prod_gw_project -p '{"spec":{"template":{"spec":{"containers":[{"name":"prod-apicast","env":[{"name":"THREESCALE_PORTAL_ENDPOINT","value":"'$newTPE'"}]}]}}}}'
  oc patch deploy stage-apicast -n $openbanking_prod_gw_project -p '{"spec":{"template":{"spec":{"containers":[{"name":"stage-apicast","env":[{"name":"THREESCALE_PORTAL_ENDPOINT","value":"'$newTPE'"}]}]}}}}'
  oc patch deploy wc-router -n $openbanking_prod_gw_project -p '{"spec":{"template":{"spec":{"containers":[{"name":"wc-router","env":  [{"name":"API_HOST","value":"'$newAPIHOST'"}]}]}}}}'

  oc delete route wc-router -n $openbanking_prod_gw_project
  oc create route edge wc-router --service=wc-router --wildcard-policy=Subdomain --hostname=wc-router.$openbanking_prod_gw_project.$new_threescale_superdomain -n $openbanking_prod_gw_project

}

refreshCICD() {
  oc delete bc jenkins-preloaded-with-jobs -n openbanking-cicd
  oc delete sa openbanking-jenkins -n openbanking-cicd
}

#enableLetsEncryptCertsOnRoutes
refreshControlPlane
refreshDataPlane
# refreshCICD

echo $new_guid > $HOME/guid
