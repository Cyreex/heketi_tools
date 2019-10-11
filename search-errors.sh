gv=$(kubectl exec -it -n glusterfs $(kubectl get po -n glusterfs | \
grep -v -E"heketi|backup|NAME" | awk '{print $1}' | \
head -1) gluster v list > /tmp/gv; sed -e "s/\r//g" /tmp/gv)

hv=$(kubectl exec -it -n glusterfs glusterfs-heketi-0 -- heketi-cli volume list | \
awk -F":"  '{print $4}'  > /tmp/hv; sed -e "s/\r//g" /tmp/hv)

echo "These volumes we have in the Heketi but don't have in the Gluster (lost data):" 
for i in $hv; do  
  count=$(echo $gv | grep $i -c) 
  if [ $count -eq 0 ]; then 
    echo $i
  fi
done

echo "These volumes we have in the Gluster but don't have in the Heketi (lost control):" 
for i in $gv; do 
  count=$(echo $hv | grep $i -c)
    if [ $count -eq 0 ]; then 
      echo $i
    fi
done

echo "These PV doesn't work, because volumes are absent in the Gluster:"
for i in $(kubectl get pv -o yaml | grep vol_ | awk '{print $2}'); do 
  count=$(echo $gv | grep $i -c)
    if [ $count -eq 0 ]; then 
      echo $i 
    fi 
done
