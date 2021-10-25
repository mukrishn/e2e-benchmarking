#!/usr/bin/env bash
export WORKLOAD=oslat

source ./common.sh

#deploy_workload
#wait_for_benchmark
assign_uuid
#run_benchmark_comparison
print_uuid
#generate_csv

if [[ ${ENABLE_SNAPPY_BACKUP} == "true" ]] ; then
 echo -e "snappy server as backup enabled"
 source ../../utils/snappy-move-results/common.sh
 csv_list=`find . -name "*.csv"` 
 mkdir files_list
 cp $csv_list ./files_list
 tar -zcvf snappy_files.tar.gz ./files_list

 export workload=oslat_test

 export snappy_path="$SNAPPY_USER_FOLDER/$runid$platform-$cluster_version-$network_type/$workload/$folder_date_time/"
 generate_metadata > metadata.json  
 ../../utils/snappy-move-results/run_snappy.sh snappy_files.tar.gz $snappy_path
 ../../utils/snappy-move-results/run_snappy.sh metadata.json $snappy_path
 store_on_elastic
 rm -rf files_list
fi
echo -e "${bold}Finished workload run_oslat_test_fromgit.sh"