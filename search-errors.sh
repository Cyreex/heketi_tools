#/bin/bash

#How to run this script:
#wget -v -O search-errors.sh  https://raw.githubusercontent.com/Cyreex/sh/master/search-errors.sh
#chmod +x search-errors.sh
#./search-errors.sh
#
#                   https://help.tpondemand.net/fix-heketi-lost-volumes/
#
#fixProblems YES - fix problems:
#  - delete folders related with noexists bricks on glusterfs
#  - delete lost LV

fixProblems="NO"

timestamp=$(date +%s)
logFileName="/tmp/SearchErrors_$timestamp.txt"

logs() { 
  case $2 in
  red) 
    echo -en '\033[31m'
  ;;
  yellow)
    echo -en '\033[33m'
  ;;
  *)
    echo -en '\033[0;32m'
  ;;
  esac

  echo $1 | tee $logFileName
  echo -en '\033[0m'
}

showCheckHeader() {
  if [ $count -eq 0 ] && [ $logMarker -eq 0 ]; then
    logs "$1"
    logMarker=1
    return $logMarker
  fi
}

read -p "Can I Fix problems? yes/NO: " fixProblems
if [ "${fixProblems^^}" = "YES" ]; then
  logs "We'll try to fix errors"
else
  logs "Fix problems disabled"
fi

#get all gluster volumes
glusterPodName=$(kubectl get po -n glusterfs -l=name=glusterfs-gluster -o jsonpath='{.items[0].metadata.name}')
gv=$(kubectl exec -n glusterfs $glusterPodName gluster v list)

#Get list of heketi volumes
hv=$(kubectl exec -n glusterfs glusterfs-heketi-0 -c heketi -- heketi-cli volume list | awk -F":" '{print $4}')

#Get list of volumes created by PV
pvs=$(kubectl get pv -o jsonpath='{.items[*].spec.glusterfs.path}')

#You can delete these volumes from heketi manually:
logMarker=0
for i in $hv; do  
  count=$(echo $gv | grep $i -c)
  showCheckHeader "These volumes we have in the Heketi but don't have in the Gluster (lost data):"

  if [ $count -eq 0 ]; then
    logs $i yellow
  fi
  if [ $count -eq 0 ] && [ "${fixProblems^^}" = "YES" ]; then
    read -p "Heketi volume $i will be deleted. To continue press 'Enter'. "
    heketi_volume_id=$(kubectl exec -n glusterfs glusterfs-heketi-0 -c heketi heketi-cli volume list | grep $i | awk '{print $1}' | cut -d":" -f2)
    kubectl exec -n glusterfs glusterfs-heketi-0 -c heketi heketi-cli volume delete $heketi_volume_id
  fi
done

logMarker=0
for i in $gv; do 
  count=$(echo $hv | grep $i -c)
  showCheckHeader "These volumes we have in the Gluster but don't have in the Heketi (lost control):"
  
  if [ $count -eq 0 ]; then
    logs $i red
  fi
done

#Looks like these PVs were created with errors
logMarker=0
for i in $pvs; do
  count=$(echo $gv | grep $i -c)
  showCheckHeader "These PV doesn't work, because volumes are absent in the Gluster:"

  if [ $count -eq 0 ]; then 
    logs $i yellow
  fi 
done

#################### Functions for investigating and fixing problems ######################

backup_brick() {
  sure="n"; read -p "Do we need to create backup of this brick? y/N: " sure
  if [ "${sure^^}" = "Y" ]; then
    logs "Copy brick $brick to $backup_dir on host"
    mkdir -p $backup_dir/$brick
    kubectl cp -n glusterfs $i:var/lib/heketi/mounts/$vol_name/$brick $backup_dir/$brick
  fi
}

remove_brick_mount_points() {
  logs "Remove mount points for brick $brick"
  kubectl exec -n glusterfs $i -- rm -rf /var/lib/heketi/mounts/$vol_name/$brick
  kubectl exec -n glusterfs $i -- sed -i.save "/${brick}/d" /var/lib/heketi/fstab
}

search_and_delete_lost_lv() {
  YELLOW='\033[0;33m'
  NORMAL='\033[0m'
  echo -e ${YELLOW}
  sure="n"; read -p "LV $brick will be deleted. Are you sure? y/N: " sure
  if [ "${sure^^}" = "Y" ]; then
    tp_name=$(kubectl exec -n glusterfs $i lvs | grep $brick | awk '{print $5}')
    logs "LV $tp_name will be deleted!" red
    kubectl exec -n glusterfs $i -- umount -f /var/lib/heketi/mounts/$vol_name/$brick 
    kubectl exec -n glusterfs $i -- lvremove -f $vol_name/$tp_name
    remove_brick_mount_points
  else
    logs "You skip deleting the brick"
  fi
  echo -e ${NORMAL}
}

inspect_brick() {
  logs "Try to inspect the brick:"
  logs "kubectl exec -n glusterfs $i -- bash" yellow
  kubectl exec -n glusterfs $i -- bash -c "mkdir -p /mnt/tmp && mount /dev/mapper/$vol_name-$brick \
    /mnt/tmp && ls -la /mnt/tmp/brick && echo ... df ... && df -h /mnt/tmp && umount -f /mnt/tmp"
  kubectl exec -n glusterfs $i -- bash -c "umount -f /mnt/tmp"
}

delete_gluster_volume() {
  RED='\033[31m'
  NORMAL='\033[0m'
  echo -e ${RED}
  sure="n"; read -p "Volume $volume will be deleted. Are you sure? y/N: " sure
  echo -e ${NORMAL}
  if [ "${sure^^}" = "Y" ]; then
    kubectl exec -n glusterfs $glusterPodName gluster volume stop $volume force
    kubectl exec -n glusterfs $glusterPodName gluster volume delete $volume
    logs "After deleting the Gluster volume you must remove the bricks in the following steps" red
  else
    logs "You skip deleting the volume"
  fi
}

######################## PAIN 00 ####################################################
# Sometimes we have Gluster Volumes that we don't use, but they take us some diskspace
#####################################################################################

echo ..................................................

logs "............. Check that volume using by PV ......................"
logMarker=0
for volume in $gv; do
  count=$(echo $pvs | grep $volume -c)
  if [[ $volume = vol_* ]]; then
    showCheckHeader "Gluster Volumes doesn't related with any PV. Maybe we have to delete them?"
  fi
  if [ $count -eq 0 ] && [[ $volume = vol_* ]]; then 
    logs $volume yellow
    logs "Try to mount this volume and inspect:"
    logs "mount.glusterfs localhost:/$volume /mnt/$volume"
    mkdir -p "/mnt/$volume"
    mount.glusterfs localhost:/$volume /mnt/$volume
    logs "Volume $volume is mounted to /mnt/$volume on localhost. You can check it out."
    logs "$(ls -la /mnt/$volume)" yellow
    echo "......... Volume disk usage ............."
    logs "$(df -h /mnt/$volume)" yellow
    read -p "Press 'Enter' to continue..."
    umount /mnt/$volume && rm -r /mnt/$volume

    if [ "${fixProblems^^}" = "YES" ]; then
      delete_gluster_volume
    fi

  fi
done

######################## PAIN 01 #####################################
#Our primary problem - we don't use LV, but LV aren't deleted. 
#We can have not enough free space in the Gluster volumes to creating a new volume or expand another one.
#This is really problem that we are need to fix ASAP. 
######################################################################

echo ..................................................

gluster_pods=$(kubectl get po -n glusterfs -l=name=glusterfs-gluster -o jsonpath='{.items[*].metadata.name}')
for i in $gluster_pods; do

  #Create the backup of fstab
  if [ "${fixProblems^^}" = "YES" ]; then
    pandora="NO"
    read -p "Are you sure you want open the Pandora Box for the POD $i? This is the last chance to stop it! yes/NO: " pandora
    
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
  kubectl get po -n glusterfs $i -o wide | tee $logFileName
  #Get information about ALL gluster volumes
  gi=$(kubectl exec -n glusterfs $i gluster v info all)
  #Get VG name that this GlusterFS container use
  vol_name=$(kubectl exec -n glusterfs $i -- ls /var/lib/heketi/mounts/ | grep vg_)
  #Get bricks registered in gluster on this container
  bricks=$(kubectl exec -n glusterfs $i -- ls /var/lib/heketi/mounts/$vol_name)
  #Find lost bricks and fix these
  logs "............ Check bricks mount paths ..................."

  logMarker=0
  for brick in $bricks; do 
    count=$(echo $gi | grep $brick -c)
    showCheckHeader "These BRICKS don't related with any VOLUMES (volumes maybe deleted):"
  
    if [ $count -eq 0 ]; then 
      logs $brick yellow
      lvcount=$(kubectl exec -n glusterfs $i -- lvdisplay | grep "LV Name" | grep $brick -c)   
      #if we didn't find LV with the name eq brick name, we can just delete folder and delete mount point in /var/lib/heketi/fstab
      case $lvcount in
        0) 
        logs "Mount point $brick don't related with any LV. We can just delete it from Gluster container"
        if [ "${fixProblems^^}" = "YES" ]; then 
          backup_brick
          remove_brick_mount_points
        fi
        ;;
        #if we find one LV, we need do backup and remove brick, then remove LV
        1)
        logs "Mount point $brick RELATED with ONE LV. We need to delete LV as well"
        #Get files from the brick
        inspect_brick
        if [ "${fixProblems^^}" = "YES" ]; then
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
  logMarker=0

  #Get bricks logical volumes
  bricks_lv=$(kubectl exec -n glusterfs $i -- lvdisplay | grep "LV Name" | grep "brick_" | awk '{print $3}')
  
  for brick in $bricks_lv; do
    count=$(echo $gi | grep $brick -c)
    showCheckHeader "These Logical Volumes (LV) don't related with any Gluster volumes (volumes maybe deleted):"

    if [ $count -eq 0 ]; then
      logs $brick yellow
      inspect_brick
      if [ "${fixProblems^^}" = "YES" ]; then
        search_and_delete_lost_lv
      fi
    fi
  done
done
