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
  echo $1 >> $logFileName
  NORMAL='\033[0m'

  case $2 in
  red) 
    COLOR="\033[31m"
  ;;
  yellow)
    COLOR="\033[33m"
  *)
    COLOR='\033[0;32m'
  ;;
  esac

  echo -en "${COLOR} $1 ${NORMAL} \n"
}

read -p "Can I Fix problems? yes/NO: " fixProblems
if [ "${fixProblems^^}" = "YES" ]; then
  logs "We'll try to fix errors"
else
  logs "Fix problems disabled"
fi

#get all gluster volumes
glusterPodName=$(kubectl get po -n glusterfs -l=name=glusterfs-gluster -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it -n glusterfs $glusterPodName gluster v list > /tmp/gv
gv=$(sed -e "s/\r//g" /tmp/gv)   #removing ^M from the end of the lines, if it exists there

#Get list of heketi volumes
kubectl exec -it -n glusterfs glusterfs-heketi-0 -- heketi-cli volume list | awk -F":" '{print $4}' > /tmp/hv
hv=$(sed -e "s/\r//g" /tmp/hv)

#Get list of volumes created by PV
kubectl get pv -o jsonpath='{.items[*].spec.glusterfs.path}' > /tmp/pvs
pvs=$(sed -e "s/\r//g" /tmp/pvs)

#You can delete these volumes from heketi manually:
logMarker=0
for i in $hv; do  
  count=$(echo $gv | grep $i -c)
  if [ $count -eq 0 ] && [ $logMarker -eq 0 ]; then
    logs "These volumes we have in the Heketi but don't have in the Gluster (lost data):"
    logMarker=1
  fi
  if [ $count -eq 0 ]; then
    logs $i
  fi
done

logMarker=0
for i in $gv; do 
  count=$(echo $hv | grep $i -c)
  if [ $count -eq 0 ] && [ $logMarker -eq 0 ]; then
    logs "These volumes we have in the Gluster but don't have in the Heketi (lost control):"
    logMarker=1
  fi
  if [ $count -eq 0 ]; then
    logs $i
  fi
done

logMarker=0
for i in $pvs; do
  count=$(echo $gv | grep $i -c)
  if [ $count -eq 0 ] && [ $logMarker -eq 0 ]; then
    logs "These PV doesn't work, because volumes are absent in the Gluster:"
    logMarker=1
  fi
  if [ $count -eq 0 ]; then 
    logs $i
  fi 
done

#################### Functions for investigating and fixing problems ######################

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
  YELLOW='\033[0;33m'
  NORMAL='\033[0m'
  echo -e ${YELLOW}
  sure="n"; read -p "LV $brick will be deleted. Are you sure? y/N: " sure
  if [ "${sure^^}" = "Y" ]; then
    logs "LV will be deleted!" red
    kubectl exec -it -n glusterfs $i -- umount -f /var/lib/heketi/mounts/$vol_name/$brick
    kubectl exec -it -n glusterfs $i -- lvremove -f $vol_name/tp_$(awk -F"_" '{print $2}' <<< $brick)
    remove_brick
  else
    logs "You skip deleting the brick" yellow
  fi
  echo -e ${NORMAL}
}

inspect_brick() {
  logs "Try to inspect the brick:"
  logs "kubectl exec -it -n glusterfs $i -- bash -c \"mkdir -p /mnt/tmp && mount /dev/mapper/$vol_name-$brick /mnt/tmp && ls -la /mnt/tmp/brick && umount -f /mnt/tmp\"" yellow
  kubectl exec -it -n glusterfs $i -- bash -c "mkdir -p /mnt/tmp && mount /dev/mapper/$vol_name-$brick \
    /mnt/tmp && ls -la /mnt/tmp/brick && echo ... df ... && df -ha | grep $brick && umount -f /mnt/tmp"
}

delete_gluster_volume() {
  RED="\033[31m"
  NORMAL="\033[0m"
  echo -e ${RED}
  sure="n"; read -p "Volume $volume will be deleted. Are you sure? y/N: " sure
  echo -e ${NORMAL}
  if [ ${sure^^} = "Y" ]; then
    kubectl exec -it -n glusterfs $glusterPodName volume stop $volume force
    kubectl exec -it -n glusterfs $glusterPodName volume delete $volume
    logs "After deleting the Gluster volume you must remove the bricks in the following steps"
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
  if [ $count -eq 0 ] && [ $logMarker -eq 0 ] && [[ $volume = vol_* ]]; then
    logs "Gluster Volumes doesn't related with any PV. Maybe we have to delete them?"
    logMarker=1
  fi
  if [ $count -eq 0 ] && [[ $volume = vol_* ]]; then 
    logs $volume
    logs "Try to mount this volume and inspect:"
    logs "mount.glusterfs localhost:/$volume /mnt/$volume"
    mkdir -p "/mnt/$volume"
    mount.glusterfs localhost:/$volume /mnt/$volume
    ls /mnt/$volume
    read -p "Volume $volume is mounted to /mnt/$volume. Inspect data and press any key to continue. Data will NOT be deleted!"
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
  #Find lost bricks and fix these
  logs "............ Check bricks mount paths ..................."

  logMarker=0
  for brick in $bricks; do 
    count=$(echo $gi | grep $brick -c)

    if [ $count -eq 0 ] && [ $logMarker -eq 0 ]; then
      logs "These BRICKS don't related with any VOLUMES (volumes maybe deleted):"
      logMarker=1
    fi
  
    if [ $count -eq 0 ]; then 
      logs $brick
      lvcount=$(kubectl exec -it -n glusterfs $i -- lvdisplay | grep "LV Name" | grep $brick -c)   
      #if we didn't find LV with the name eq brick name, we can just delete folder and delete mount point in /var/lib/heketi/fstab
      case $lvcount in
        0) 
        logs "Mount point $brick don't related with any LV. We can just delete it from Gluster container"
        if [ "${fixProblems^^}" = "YES" ]; then 
          backup_brick
          remove_brick
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
  kubectl exec -it -n glusterfs $i -- lvdisplay | grep "LV Name" | grep "brick_" | awk '{print $3}' > /tmp/bricks_lv
  bricks_lv=$(sed -e "s/\r//g" /tmp/bricks_lv)
  
  for brick in $bricks_lv; do
    count=$(echo $gi | grep $brick -c)

    if [ $count -eq 0 ] && [ $logMarker -eq 0 ]; then
      logs "These Logical Volumes (LV) don't related with any Gluster volumes (volumes maybe deleted):"
      logMarker=1
    fi

    if [ $count -eq 0 ]; then
      logs $brick
      if [ "${fixProblems^^}" = "YES" ]; then
        inspect_brick
        search_and_delete_lost_lv
      fi
    fi
  done
done
