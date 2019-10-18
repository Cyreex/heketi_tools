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
search_unused_bricks() {
  echo "Brick $brick don't don't related with any LV. We can just delete it from Gluster container"
  #softfix: copy this folder to /tmp (will be deleted after container restart)
  echo "Copy brick $brick to $backup_folder on host"
  kubectl cp -n glusterfs $i:var/lib/heketi/mounts/$vol_name/$brick /tmp/$backup_folder
  echo "Remove brick $brick"
  kubectl exec -it -n glusterfs $i -- rm -rf /var/lib/heketi/mounts/$vol_name/$brick
}

search_and_delete_lost_lv() {
  if [ $lvcount -eq 1 ]; then
    sure="n"; echo -p "LV $brick will be deleted. Are you sure? y/N" sure
    #Third "if" makes me cry, but looks so clear and safe... 
    if [ ${sure^^} = "Y"]; then
      echo "LV will be deleted!"
      kubectl exec -it -n glusterfs $i -- lvremove -f $vol_name/tp_$(awk -F"_" '{print $2}' <<< $brick)
    else
      echo "Oh, dude..."
    fi
  fi

}

echo "These BRICKS don't related with any VOLUMES (volumes maybe deleted):"

gluster_pods=$(kubectl get po -n glusterfs | grep -v -E"heketi|backup|NAME" | awk '{print $1}')
for i in $gluster_pods; do

  #Create the backup of fstab
  if [ ${softfix^^} = "YES"]; then
    backup_dir="/tmp/backup_$i_$(date +%s)"
    mkdir $backup_dir
    kubectl cp -n glusterfs $i:var/lib/heketi/fstab $backup_dir
  fi
  #Show GlusterFS POD which we use in this step
  kubectl get po -n glusterfs $i -o wide
  #Get information about ALL gluster volumes
  gi=$(kubectl exec -it -n glusterfs $i gluster v info all > /tmp/gi; sed -e "s/\r//g" /tmp/gi)
  #Get VG name that this GlusterFS container use
  vol_name=$(kubectl exec -it -n glusterfs $i -- ls /var/lib/heketi/mounts/ | grep vg_ > /tmp/vol_name; sed -e "s/\r//g" /tmp/vol_name)
  #Get bricks registered in gluster on this container
  bricks=$(kubectl exec -it -n glusterfs $i -- ls /var/lib/heketi/mounts/$vol_name > /tmp/brick; sed -e "s/\r//g" /tmp/brick)
  #Find lost bricks and fix these
  for brick in $bricks; do 
    count=$(echo $gi | grep $brick -c)
      if [ $count -eq 0 ]; then 
        echo $brick
        lvcount=$(kubectl exec -it -n glusterfs $i -- lvdisplay | grep $brick -c)
        if [ $lvcount -eq 0 ]; then
          echo "Brick $brick don't don't related with any LV. We can just delete it from Gluster container"
          if [ ${softfix^^} = "YES"]; then search_unused_bricks; fi
        fi
        if [ $lvcount -eq 1 ]; then
          echo "Brick $brick RELATED with ONE LV. We need to delete LV as well"
          if [ ${hardfix^^} = "YES"]; then search_and_delete_lost_lv; fi
        fi 
       
      fi
  done
done

###Function that we can run MANUALLY in Gluster container
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
