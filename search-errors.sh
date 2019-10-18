#/bin/bash

#How to run this script:
#wget -v -O search-errors.sh  https://raw.githubusercontent.com/Cyreex/sh/master/search-errors.sh
#chmod +x search-errors.sh
#./search-errors.sh
#
#                   https://help.tpondemand.net/fix-heketi-lost-volumes/
#
#softfix YES - make some soft fix:
#  - delete folders related with noexists bricks on glusterfs
softfix="NO"
hardfix="NO"

read -p "Can I make Soft Fix? yes/NO:" softfix
if [ "${softfix^^}" = "YES" ]; then
  echo "We'll delete folders for noexists bricks"
  read -p "Can we do Hard Fix? Are you sure? yes/NO" hardfix
else
  echo "Soft fix is disabled"
fi

if [ "${hardfix^^}" = "YES" ]; then
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
#You can delete these volumes from heketi manually:
#
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

######################## PAIN ########################################
#Our primary problem - we don't use LV, but LV aren't deleted. 
#We can have not enough free space in the Gluster volumes to creating a new volume or expand another one.
#This is really problem that we are need to fix ASAP. 
#####################################################################

backup_brick() {
  echo "Copy brick $brick to $backup_folder on host"
  kubectl cp -n glusterfs $i:var/lib/heketi/mounts/$vol_name/$brick /tmp/$backup_folder
}

remove_brick() {
  echo "Remove brick $brick"
  kubectl exec -it -n glusterfs $i -- rm -rf /var/lib/heketi/mounts/$vol_name/$brick; sed -i.save "/${brick}/d" /var/lib/heketi/fstab
}

search_and_delete_lost_lv() {
  backup_brick
  sure="n"; echo -p "LV $brick will be deleted. Are you sure? y/N" sure
  if [ "${sure^^}" = "Y"]; then
    echo "LV will be deleted!"
    kubectl exec -it -n glusterfs $i -- umount /var/lib/heketi/mounts/$vol_name/$brick; \
      lvremove -f $vol_name/tp_$(awk -F"_" '{print $2}' <<< $brick)
    remove_brick
  else
    echo "Oh, dude..."
  fi
}

echo "These BRICKS don't related with any VOLUMES (volumes maybe deleted):"

gluster_pods=$(kubectl get po -n glusterfs | grep -v -E"heketi|backup|NAME" | awk '{print $1}')
for i in $gluster_pods; do

  #Create the backup of fstab
  if [ "${softfix^^}" = "YES"]; then
    pandora="NO"
    echo -p "Are you sure you want open the Pandora Box for the POD $i? This is the last chance to stop it! yes/NO" pandora
    if [ "${pandora^^}" = "YES" ]; then
      echo "LET'S ROCK!" 
    else 
      echo "Good choise, man!" 
      exit 1 
    fi
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
      lvcount=$(kubectl exec -it -n glusterfs $i -- lvdisplay | grep "LV Name" | grep $brick -c)   
      #if we didn't find LV with the name eq brick name, we can just delete folder and delete mount point in /var/lib/heketi/fstab
      case $lvcount in
        0) 
        echo "Brick $brick don't don't related with any LV. We can just delete it from Gluster container"
        if [ "${softfix^^}" = "YES" ]; then backup_brick; remove_brick; fi
        ;;
        #if we find one LV, we need do backup and remove brick, then remove LV
        1)
        echo "Brick $brick RELATED with ONE LV. We need to delete LV as well"
        if [ "${hardfix^^}" = "YES" ]; then search_and_delete_lost_lv; fi
        ;;
        #If we found more than one volume - this is so strange... Better check it manually
        *)
        echo "ERROR: Something went wrong with brick $brick - lvcount=$lvcount"
        ;;
      esac
    fi
  done
done

#Resync heketi volumes
if [ "${softfix^^}" = "YES"]; then
  kubectl exec -it -n glusterfs glusterfs-heketi-0 -- \
    for i in $(heketi-cli topology info | grep Free | awk '{print $1}' | cut -d":" -f 2); do \
    heketi-cli device resync $i; done
fi
