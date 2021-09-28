export ES_SERVER=
export METADATA_COLLECTION=true
export COMPARE=false
export COMPARE_WITH_GOLD=
export GOLD_SDN=
export GOLD_OCP_VERSION=
export ES_GOLD=
export BASELINE_CLOUD_NAME=
export ES_SERVER_BASELINE=
#export CERBERUS_URL=http://1.2.3.4:8080
#export GSHEET_KEY_LOCATION=
#export EMAIL_ID_FOR_RESULTS_SHEET=<your_email_id>  # Will only work if you have google service account key
# testpmd specific variables
export PRIVILEGED=${PRIVILEGED:-true}
export PIN=${PIN:-true}
export PIN_TESTPMD=${PIN_TESTPMD:-worker-0}
export PIN_TREX=${PIN_TREX:-worker-1}
export SOCKET_MEMORY=${SOCKET_MEMORY:-"0,1024"}
export NETWORK_NAME=${NETWORK_NAME:-testpmd-sriov-network}
export TESTPMD_NETWORK_COUNT=${TESTPMD_NETWORK_COUNT:-2}
export TREX_NETWORK_COUNT=${TREX_NETWORK_COUNT:-2}

