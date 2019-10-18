#/bin/bash

#softfix YES - make some soft fix:
#  - delete folders related with noexists bricks on glusterfs
read -p "Can I make Soft Fix? yes/NO:" softfix
if [ ${softfix^^} = "YES" ]; then
  echo "We'll delete folders for noexists bricks"
  read -p "Can we do Hard Fix? Are you sure? yes/NO" hardfix
else
  echo "Soft fix is disabled"
fi

if [ ${hardfix^^} = "YES" ]; then
  echo "Hard Fix is enabled! Get ready to save you ass!"
else
  echo "Hard fix is disabled. Your ass is safe :)"
fi

#get all gluster volumes
gv=$(kubectl exec -it -n glusterfs $(kubectl get po -n glusterfs | \
grep -v -E"heketi|backup|NAME" | awk '{print $1}' | \
head -1) gluster v list > /tmp/gv; sed -e "s/\r//g" /tmp/gv)

#Get list of heketi volumes
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

####
search_lv_and fix_it() {
  lvcount=$(kubectl exec -it -n glusterfs $i -- lvs | grep $brick -c)
  fstabcount=$(kubectl exec -it -n glusterfs $i -- cat /var/lib/heketi/fstab| grep $brick -c)
  if [ $lvcount -ne 0 ]; then
    echo "lv is EXISTS"
  else
    echo "lv doesn't exists!"
    #softfix: move this folder to /tmp (will be deleted after container restart)
    if [ $fstabcount -eq 0 ] && [ ${softfix^^} = "YES"]; then
      echo "$move brick $brick to /tmp"
      kubectl exec -it -n glusterfs $i -- mv /var/lib/heketi/mounts/$vol_name/$brick /tmp/
    fi
    if [ $fstabcount -ne 0 ] && [ ${softfix^^} = "YES"]; then
      echo "$move brick $brick to /tmp"
      kubectl exec -it -n glusterfs $i -- mv /var/lib/heketi/mounts/$vol_name/$brick /tmp/
      echo "Delete mount point for brick $brick from the fstab"
    fi    
  fi
}

echo "These BRICKS don't related with any VOLUMES (volumes maybe deleted):"

gluster_pods=$(kubectl get po -n glusterfs | grep -v -E"heketi|backup|NAME" | awk '{print $1}')
for i in $gluster_pods; do
  kubectl get po -n glusterfs $i -o wide
  gi=$(kubectl exec -it -n glusterfs $i gluster v info all > /tmp/gi; sed -e "s/\r//g" /tmp/gi)
  vol_name=$(kubectl exec -it -n glusterfs $i -- ls /var/lib/heketi/mounts/ | grep vg_ > /tmp/vol_name; sed -e "s/\r//g" /tmp/vol_name)
  bricks=$(kubectl exec -it -n glusterfs $i -- ls /var/lib/heketi/mounts/$vol_name > /tmp/brick; sed -e "s/\r//g" /tmp/brick)
  for brick in $bricks; do 
    count=$(echo $gi | grep $brick -c)
      if [ $count -eq 0 ]; then 
        echo $brick
        kubectl exec -it -n glusterfs $i -- search_lv_and fix_it
      fi
  done
done

###Function that we run manually in Gluster container
delete_bricks_without_lvs() {
  vol_name=$(ls /var/lib/heketi/mounts/ | grep vg_)
  bricks=$(ls /var/lib/heketi/mounts/$vol_name)
  for brick in $bricks; do 
    count=$(lvdisplay | grep Name| grep $brick -c)
    if [ $count -eq 0 ]; then
      fstab=$(cat /var/lib/heketi/fstab | grep $brick -c)
        if [ $fstab -eq 0 ]; then 
          echo "We can JUST delete the brick $brick"
        else 
          echo "We need to change FSTAB for $brick"
        fi
    fi
  done
}
