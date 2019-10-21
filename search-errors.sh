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
#hardfix YES - lost LV will be deleted!

softfix="NO"
hardfix="NO"

timestamp=$(date +%s)
logFileName="/tmp/SearchErrors_$timestamp.txt"

logs() { 
  echo $1 >> $logFileName
  GREEN='\033[0;32m'
  NORMAL='\033[0m'
  echo -en "${GREEN} $1 ${NORMAL} \n"
}

read -p "Can I make Soft Fix? yes/NO: " softfix
if [ "${softfix^^}" = "YES" ]; then
  logs "We'll delete folders for noexists bricks"
  read -p "Can we do Hard Fix? Are you sure? yes/NO " hardfix
else
  logs "Soft fix is disabled"
fi

if [ "${hardfix^^}" = "YES" ]; then
  logs "Hard Fix is enabled! Get ready to save you ass!"
else
  logs "Hard fix is disabled. Your ass is safe :)"
fi

#get all gluster volumes
kubectl exec -it -n glusterfs $(kubectl get po -n glusterfs -l=name=glusterfs-gluster -o jsonpath='{.items[0].metadata.name}') gluster v list > /tmp/gv
gv=$(sed -e "s/\r//g" /tmp/gv)   #removing ^M from the end of the lines, if it exists there

#Get list of heketi volumes
kubectl exec -it -n glusterfs glusterfs-heketi-0 -- heketi-cli volume list | awk -F":" '{print $4}' > /tmp/hv
hv=$(sed -e "s/\r//g" /tmp/hv)

logs "These volumes we have in the Heketi but don't have in the Gluster (lost data):"
#You can delete these volumes from heketi manually:
for i in $hv; do  
  count=$(echo $gv | grep $i -c) 
  if [ $count -eq 0 ]; then 
    logs $i
  fi
done

logs "These volumes we have in the Gluster but don't have in the Heketi (lost control):" 
for i in $gv; do 
  count=$(echo $hv | grep $i -c)
    if [ $count -eq 0 ]; then 
      logs $i
    fi
done

logs "These PV doesn't work, because volumes are absent in the Gluster:"
for i in $(kubectl get pv -o yaml | grep vol_ | awk '{print $2}'); do 
  count=$(echo $gv | grep $i -c)
    if [ $count -eq 0 ]; then 
      logs $i 
    fi 
done

######################## PAIN ########################################
#Our primary problem - we don't use LV, but LV aren't deleted. 
#We can have not enough free space in the Gluster volumes to creating a new volume or expand another one.
#This is really problem that we are need to fix ASAP. 
#####################################################################

echo ..................................................
echo ..................................................

backup_brick() {
  logs "Copy brick $brick to $backup_dir on host"
  mkdir -p $backup_dir/$brick
  kubectl cp -n glusterfs $i:var/lib/heketi/mounts/$vol_name/$brick $backup_dir/$brick
}

remove_brick() {
  logs "Remove brick $brick"
  kubectl exec -it -n glusterfs $i -- rm -rf /var/lib/heketi/mounts/$vol_name/$brick
  kubectl exec -it -n glusterfs $i -- sed -i.save "/${brick}/d" /var/lib/heketi/fstab
}

search_and_delete_lost_lv() {  
  sure="n"; read -p "LV $brick will be deleted. Are you sure? y/N " sure
  if [ "${sure^^}" = "Y" ]; then
    logs "LV will be deleted!"
    kubectl exec -it -n glusterfs $i -- umount -f /var/lib/heketi/mounts/$vol_name/$brick
    kubectl exec -it -n glusterfs $i -- lvremove -f $vol_name/tp_$(awk -F"_" '{print $2}' <<< $brick)
    remove_brick
  else
    logs "Oh, dude..."
  fi
}

inspect_brick() {
  logs "Try to inspect the brick:"
  logs "kubectl exec -it -n glusterfs $i -- bash -c \"mkdir -p /mnt/tmp && mount /dev/mapper/$vol_name-$brick /mnt/tmp && ls -la /mnt/tmp/brick && umount -f /mnt/tmp\""
  kubectl exec -it -n glusterfs $i -- bash -c "mkdir -p /mnt/tmp && mount /dev/mapper/$vol_name-$brick \
    /mnt/tmp && ls -la /mnt/tmp/brick && echo ... df ... && df -ha | grep $brick && umount -f /mnt/tmp"
}

logs "These BRICKS don't related with any VOLUMES (volumes maybe deleted):"

gluster_pods=$(kubectl get po -n glusterfs -l=name=glusterfs-gluster -o jsonpath='{.items[*].metadata.name}')
for i in $gluster_pods; do

  #Create the backup of fstab
  if [ "${softfix^^}" = "YES" ]; then
    pandora="NO"
    read -p "Are you sure you want open the Pandora Box for the POD $i? This is the last chance to stop it! yes/NO " pandora
    
    if [ "${pandora^^}" = "YES" ]; then 
      logs "LET'S ROCK!"
    else 
      logs "Good choise, man!"
      exit 1 
    fi

    backup_dir="/tmp/backup_$i_$timestamp"
    mkdir $backup_dir
    kubectl cp -n glusterfs $i:var/lib/heketi/fstab $backup_dir
  fi
  #Show GlusterFS POD which we use in this step
  kubectl get po -n glusterfs $i -o wide
  #Get information about ALL gluster volumes
  kubectl exec -it -n glusterfs $i gluster v info all > /tmp/gi
  gi=$(sed -e "s/\r//g" /tmp/gi)
  #Get VG name that this GlusterFS container use
  kubectl exec -it -n glusterfs $i -- ls /var/lib/heketi/mounts/ | grep vg_ > /tmp/vol_name
  vol_name=$(sed -e "s/\r//g" /tmp/vol_name)
  #Get bricks registered in gluster on this container
  kubectl exec -it -n glusterfs $i -- ls /var/lib/heketi/mounts/$vol_name > /tmp/brick
  bricks=$(sed -e "s/\r//g" /tmp/brick)
  #Get bricks logical volumes
  kubectl exec -it -n glusterfs $i -- lvdisplay | grep "LV Name" | grep "brick_" | awk '{print $3}' > /tmp/brick_lv
  bricks_lv=$(sed -e "s/\r//g" /tmp/brick_lv)
  #Find lost bricks and fix these
  logs "............ Check bricks mount paths ..................."
  for brick in $bricks; do 
    count=$(echo $gi | grep $brick -c)
    if [ $count -eq 0 ]; then 
      logs $brick
      lvcount=$(kubectl exec -it -n glusterfs $i -- lvdisplay | grep "LV Name" | grep $brick -c)   
      #if we didn't find LV with the name eq brick name, we can just delete folder and delete mount point in /var/lib/heketi/fstab
      case $lvcount in
        0) 
        logs "Brick $brick don't don't related with any LV. We can just delete it from Gluster container"
        if [ "${softfix^^}" = "YES" ]; then 
          backup_brick 
          remove_brick
        fi
        ;;
        #if we find one LV, we need do backup and remove brick, then remove LV
        1)
        logs "Brick $brick RELATED with ONE LV. We need to delete LV as well"
        #Get files from the brick
        inspect_brick
        if [ "${hardfix^^}" = "YES" ]; then
          backup_brick
          search_and_delete_lost_lv
        fi
        ;;
        #If we found more than one volume - this is so strange... Better check it manually
        *)
        logs "ERROR: Something went wrong with brick $brick - lvcount=$lvcount"
        ;;
      esac
    fi
  done

  #Search brick LVs which don't related with any gluster Volume
  logs "............ Check bricks lvs ..................."
  logs "These Logical Volumes (LV) don't related with any Gluster volumes (volumes maybe deleted):"
  for brick_lv in $bricks_lv; do
    count=$(echo $gi | grep $brick_lv -c)
    if [ $count -eq 0 ]; then
      logs $brick
      if [ "${hardfix^^}" = "YES" ]; then
        inspect_brick
        search_and_delete_lost_lv
      fi
    fi
  done
done
