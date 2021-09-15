source env.sh

# If ES_SERVER is set and empty we disable ES indexing and metadata collection
if [[ -v ES_SERVER ]] && [[ -z ${ES_SERVER} ]]; then
  export METADATA_COLLECTION=false
else
  export PROM_TOKEN=$(oc -n openshift-monitoring sa get-token prometheus-k8s)
fi
export NODE_SELECTOR_KEY="node-role.kubernetes.io/worker"
export NODE_SELECTOR_VALUE=""
export WAIT_WHEN_FINISHED=true
export WAIT_FOR=[]
export TOLERATIONS="[{key: role, value: workload, effect: NoSchedule}]"
export UUID=$(uuidgen)

log() {
  echo ${bold}$(date -u):  ${@}${normal}
}

check_cluster_present() {
  echo ""
  oc get clusterversion
  if [ $? -ne 0 ]; then
    log "Workload Failed for cloud $cloud_name, Unable to connect to the cluster"
    exit 1
  fi
  cluster_version=$(oc get clusterversion --no-headers | awk '{ print $2 }')
  echo ""
}

check_cluster_health() {
  if [[ ${CERBERUS_URL} ]]; then
    response=$(curl ${CERBERUS_URL})
    if [ "$response" != "True" ]; then
      log "Cerberus status is False, Cluster is unhealthy"
      exit 1
    fi
  fi
}

export_defaults() {
  operator_repo=${OPERATOR_REPO:=https://github.com/cloud-bulldozer/benchmark-operator.git}
  operator_branch=${OPERATOR_BRANCH:=master}
  CRD=${CRD:-ripsaw-oslat-crd.yaml}
  export _es=${ES_SERVER:-https://search-perfscale-dev-chmf5l4sh66lvxbnadi4bznl3a.us-west-2.es.amazonaws.com:443}
  _es_baseline=${ES_SERVER_BASELINE:-https://search-perfscale-dev-chmf5l4sh66lvxbnadi4bznl3a.us-west-2.es.amazonaws.com:443}
  export _metadata_collection=${METADATA_COLLECTION:=true}
  export _metadata_targeted=true
  export COMPARE=${COMPARE:=false}
  network_type=$(oc get network cluster  -o jsonpath='{.status.networkType}' | tr '[:upper:]' '[:lower:]')
  gold_sdn=${GOLD_SDN:=openshiftsdn}
  export baremetalCheck=$(oc get infrastructure cluster -o json | jq .spec.platformSpec.type)

  if [[ -z "$GSHEET_KEY_LOCATION" ]]; then
     export GSHEET_KEY_LOCATION=$HOME/.secrets/gsheet_key.json
  fi

  if [ ! -z ${2} ]; then
    export KUBECONFIG=${2}
  fi

  cloud_name=$1
  if [ "$cloud_name" == "" ]; then
    export cloud_name="${network_type}_${platform}_${cluster_version}"
  fi

  if [[ ${COMPARE} == "true" ]]; then
    echo $BASELINE_CLOUD_NAME,$cloud_name > uuid.txt
  else
    echo $cloud_name > uuid.txt
  fi
}

deploy_perf_profile() {
  if [[ "${baremetalCheck}" == '"BareMetal"' ]]; then
    log "Trying to find 2 suitable nodes only for oslat"
    # iterate over worker nodes bareMetalHandles until we have at least 2 
    worker_count=0
    oslat_workers=()
    #workers=$(oc get bmh -n openshift-machine-api | grep worker | awk '{print $1}')
    workers=$(oc get nodes | grep ^worker | awk '{print $1}')
    until [ $worker_count -eq 2 ]; do
      for worker in $workers; do
        #worker_ip=$(oc get bmh $worker -n openshift-machine-api -o go-template='{{range .status.hardware.nics}}{{.name}}{{" "}}{{.ip}}{{"\n"}}{{end}}' | grep 192)
	worker_ip=$(oc get node $worker -o json | jq -r ".status.addresses[0].address" | grep 192 )
        if [[ ! -z "$worker_ip" ]]; then
          oslat_workers+=( $worker )
          ((worker_count=worker_count+1))
        fi
      done
    done
  fi

  # label the two nodes for the performance profile
  # https://github.com/cloud-bulldozer/benchmark-operator/blob/master/docs/testpmd.md#sample-pao-configuration
  log "Labeling -lat nodes"
  for w in ${oslat_workers[@]}; do
    oc label node $w node-role.kubernetes.io/worker-lat="" --overwrite=true
  done
  # create the machineconfigpool
  log "Create the MCP"
  oc create -f machineconfigpool.yaml
  sleep 30
  if [ $? -ne 0 ] ; then
    log "Couldn't create the MCP, exiting!"
    exit 1
  fi
  # add the label to the MCP pool 
  log "Labeling the MCP"
  oc label mcp worker-lat machineconfiguration.openshift.io/role=worker-lat
  if [ $? -ne 0 ] ; then
    log "Couldn't label the MCP, exiting!"
    exit 1
  fi
  # apply the performanceProfile
  log "Applying the performanceProfile if it doesn't exist yet"
  profile=$(oc get performanceprofile oslat-performance-profile-0 --no-headers)
  if [ $? -ne 0 ] ; then
    log "PerformanceProfile not found, creating it"
    oc apply -f perf_profile.yaml
    if [ $? -ne 0 ] ; then
      # something when wrong with the perfProfile, bailing out
      log "Couldn't apply the performance profile, exiting!"
      exit 1
    fi
    # We need to wait for the nodes with the perfProfile applied to to reboot
    log "Sleeping for 60 seconds"
    sleep 60
    readycount=$(oc get mcp worker-lat --no-headers | awk '{print $7}')
    while [[ $readycount -ne 2 ]]; do
      log "Waiting for -lat nodes to become ready again, sleeping 1 minute"
      sleep 60
      readycount=$(oc get mcp worker-lat --no-headers | awk '{print $7}')
    done
  fi
}

deploy_operator() {
  log "Removing benchmark-operator namespace, if it already exists"
  oc delete namespace benchmark-operator --ignore-not-found
  log "Cloning benchmark-operator from branch ${operator_branch} of ${operator_repo}"
  rm -rf benchmark-operator
  git clone --single-branch --branch ${operator_branch} ${operator_repo} --depth 1
  (cd benchmark-operator && make deploy)
  oc wait --for=condition=available "deployment/benchmark-controller-manager" -n benchmark-operator --timeout=300s
  oc adm policy -n benchmark-operator add-scc-to-user privileged -z benchmark-operator
  oc adm policy -n benchmark-operator add-scc-to-user privileged -z backpack-view
  oc patch scc restricted --type=merge -p '{"allowHostNetwork": true}'
}

deploy_workload() {
  log "Deploying oslat benchmark"
  envsubst < $CRD | oc apply -f -
  #envsubst < $CRD > /tmp/oslat.yaml
  log "Sleeping for 60 seconds"
  sleep 60
}

wait_for_benchmark() {
  oslat_state=1
  for i in {1..480}; do # 2hours
    update
    if [ "${benchmark_state}" == "Error" ]; then
      log "Cerberus status is False, Cluster is unhealthy"
      exit 1
    fi
    oc describe -n benchmark-operator benchmarks/oslat | grep State | grep Complete
    if [ $? -eq 0 ]; then
      log "oslat workload done!"
      oslat_state=$?
      break
    fi
    update
    log "Current status of the oslat ${WORKLOAD} benchmark is ${uline}${benchmark_state}${normal}"
    check_logs_for_errors
    sleep 30
  done

  if [ "$oslat_state" == "1" ] ; then
    log "Workload failed"
    exit 1
  fi
}

init_cleanup() {
  if [[ "${isBareMetal}" == "false" ]]; then
    log "Cloning benchmark-operator from branch ${operator_branch} of ${operator_repo}"
    rm -rf /tmp/benchmark-operator
    git clone --single-branch --branch ${operator_branch} ${operator_repo} /tmp/benchmark-operator --depth 1
    oc delete -f /tmp/benchmark-operator/deploy
    oc delete -f /tmp/benchmark-operator/resources/crds/ripsaw_v1alpha1_ripsaw_crd.yaml
    oc delete -f /tmp/benchmark-operator/resources/operator.yaml
  else
    log "BareMetal Instrastructure: Skipping cleanup"
  fi
}

export TERM=screen-256color
bold=$(tput bold)
uline=$(tput smul)
normal=$(tput sgr0)
python3 -m pip install -r requirements.txt | grep -v 'already satisfied'
check_cluster_present
export_defaults
init_cleanup
check_cluster_health
deploy_perf_profile
deploy_operator
