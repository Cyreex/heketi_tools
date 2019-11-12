#С каким волумом работаем, его размер и производные от них
export volume_name=vol_16c8b695505950ccc604e60e68c9de37
export volume_size=2

input_json=before.json
kubectl cp -n glusterfs glusterfs-heketi-0:var/lib/heketi/$input_json ./

export volume_size_bytes=$(($volume_size*1048576))
export volume_id=$(cut -d_ -f2 <<< $volume_name)

#Генерируем GID волума 
maxGid=$(grep gid $input_json | sort | tail -n 1 | awk '{print $2}' | cut -d, -f1)
export volume_gid=$((maxGid+1))

#Выцепляем ID кластера из хекети
export cluster_id=$(kubectl exec -n glusterfs glusterfs-heketi-0 -c heketi -- heketi-cli cluster list | tail -n1 | awk '{print $1}' | cut -d: -f2)

nodes=$(kubectl exec -n glusterfs glusterfs-heketi-0 -c heketi -- heketi-cli node list | awk '{print $1}' | cut -d: -f2)
echo $nodes
#Объявляем два массива для айпишников и айдишников нод в хекети
declare -A node_ip=()
declare -A node_heketi_id=()

#counter
counter=1

for node in $nodes; do
  node_ip[$node]=$(kubectl exec -n glusterfs glusterfs-heketi-0 -c heketi -- heketi-cli node info $node | grep "Storage Hostname:" | awk '{print $3}')
  export declare "gluster_host_ip_$counter=${node_ip[$node]}"
  #node_heketi_id Используется при добавлении айдишников томов в deviceentries (последний шаг)
  node_heketi_id[$node]=$(kubectl exec -n glusterfs glusterfs-heketi-0 -c heketi -- heketi-cli node info $node | grep ^Id: | awk '{print $1}' | cut -d: -f2)
  counter=$((counter+1))
done

bricks=$(kubectl exec -n glusterfs $(kubectl get po -n glusterfs -l=name=glusterfs-gluster -o jsonpath='{.items[0].metadata.name}') gluster v info $volume_name | grep Brick[123] | awk '{print $2}')

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
jq '.brickentries += input.bricks' tempDB.json full-with-values.json > tempDB1.json
jq --arg volume_id $volume_id --arg cluster_id $cluster_id  '.clusterentries[].Info.volumes[ .clusterentries[].Info.volumes | length ] +=  $volume_id' tempDB1.json > tempDB2.json

jq --arg id $id --arg text xxx '.deviceentries | .[$id].Bricks[ .[$id].Bricks | length ] += $text' deviceentries.json


#deviceentries


jq --arg volume_id $volume_id --arg cluster_id $cluster_id '.clusterentries | .[$cluster_id].Info.volumes[17] +=  $volume_id' tempDB1.json

jq --arg volume_id $volume_id --arg cluster_id $cluster_id  '.clusterentries[].Info.volumes[ .clusterentries[].Info.volumes | length ] +=  $volume_id' tempDB1.json
