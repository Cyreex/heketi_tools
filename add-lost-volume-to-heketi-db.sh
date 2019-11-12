if [[ ${1} != "vol_"*  ]]; then
  echo "You enter not correct volume name!"
  echo "Example:"
  echo "add-lost-volume-to-heketi-db.sh vol_16c8b695505950ccc604e60e68c9de37"   
  exit 0
fi 

set -e

export volume_name=$1

input_json=before.json
kubectl cp -n glusterfs glusterfs-heketi-0:var/lib/heketi/$input_json ./

export volume_id=$(cut -d_ -f2 <<< $volume_name)

#Generate GID for a volume
maxGid=$(grep gid $input_json | sort | tail -n 1 | awk '{print $2}' | cut -d, -f1)
export volume_gid=$((maxGid+1))

#Get the cluster ID from heketi
export cluster_id=$(kubectl exec -n glusterfs glusterfs-heketi-0 -c heketi -- heketi-cli cluster list | tail -n1 | awk '{print $1}' | cut -d: -f2)

#Get all gluster nodes registered in Heketi
nodes=$(kubectl exec -n glusterfs glusterfs-heketi-0 -c heketi -- heketi-cli node list | awk '{print $1}' | cut -d: -f2)

declare -A node_ip=()
counter=1

for node in $nodes; do
  node_ip[$node]=$(kubectl exec -n glusterfs glusterfs-heketi-0 -c heketi -- heketi-cli node info $node | grep "Storage Hostname:" | awk '{print $3}')
  export declare "gluster_host_ip_$counter=${node_ip[$node]}"
  counter=$((counter+1))
done

gluster_pod=$(kubectl get po -n glusterfs -l=name=glusterfs-gluster -o jsonpath='{.items[0].metadata.name}')

bricks=$(kubectl exec -n glusterfs $gluster_pod gluster v info $volume_name | grep Brick[123] | awk '{print $2}')
export volume_size=$(kubectl exec -n glusterfs $gluster_pod gluster v status $volume_name detail | grep "Total Disk Space" -m1 | awk '{print $5}' | cut -d. -f1)
export volume_size_bytes=$(($volume_size*1048576))

counter=1
for brick in $bricks; do
  export declare "brick_id_$counter=$(echo $brick | awk -F/ '{print $(NF-1)}' | cut -d_ -f2)"
  export declare "brick_path_$counter=$(cut -d: -f2 <<< $brick)"
  export declare "brick_vg_id_$counter=$(echo $brick | awk -F/ '{print $(NF-2)}' | cut -d_ -f2)"
  brick_ip=$(cut -d: -f1 <<< $brick)
  export declare "host_id_for_brick_id_$counter=$(for node in $nodes; do if [ "${node_ip[$node]}" = "$brick_ip" ]; then echo $node; fi; done)"
  counter=$((counter+1))
done



###GLUE
#replace variables in JSON template
envsubst < full.json > full-with-values.json

#Add volume to Heketi DB (JSON)
jq '.volumeentries += input.volume' $input_json full-with-values.json > tempDB.json
jq '.brickentries += input.bricks' tempDB.json full-with-values.json > tempDB.tmp && mv tempDB.tmp tempDB.json

jq --arg volume_id $volume_id --arg cluster_id $cluster_id  '.clusterentries[].Info.volumes[ .clusterentries[].Info.volumes | length ] +=  $volume_id' tempDB.json > tempDB.tmp && mv tempDB.tmp tempDB.json

deviceentries() {
  jq --arg brick_id $1 --arg host_id $2 '.deviceentries | .[$host_id].Bricks[ .[$host_id].Bricks | length ] += $brick_id' tempDB.json > deviceentries.tmp
  jq ".deviceentries = input" tempDB.json deviceentries.tmp > tempDB.tmp && mv tempDB.tmp tempDB.json && rm -f deviceentries.tmp
}


deviceentries $brick_id_1 $brick_vg_id_1
deviceentries $brick_id_2 $brick_vg_id_2
deviceentries $brick_id_2 $brick_vg_id_3

mv tempDB.json after.json

kubectl cp -n glusterfs ./after.json glusterfs-heketi-0:var/lib/heketi/
