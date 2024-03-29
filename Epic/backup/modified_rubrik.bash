#!/usr/bin/bash

set -ex

#------------------------------------------------------------------------------

# Copyright (c) 2021 Nutanix Inc. All rights reserved.
#
# Owner:   epic@nutanix.com
# Authors: scott.fadden@nutanix.com
#          jon@nutanix.com

#------------------------------------------------------------------------------

## About
# This script is used to manage data cloning and out-of-system backups for
# Epic's Operational Database, based on InterSystems IRIS, when running on
# top of Nutanix AOS storage and Nutanix Acropolis Hypervisor (AHV).
#
# This script is intended to be a functional sample to assist with managing
# backups in a production Epic ODB implementation. Modifications will be
# required to "personalize" this script to the target environment.
#
# This script is designed to run within a CentOS/Redhat VM that does *not*
# run Epic ODB itself, but rather acts as an "utility" VM to both schedule
# the execution of this script as well as act as the "backup target" for
# your chosen 3rd party backup software.
#
# This "utility" VM needs to be run in the same AHV cluster as the Epic ODB
# instances to be backed up, so that we can mount the volume groups in a
# hot-add manner.
#
# The script is designed to handle a single Epic environment at a time, such
# that you can have multiple instantiations of this same script to manage the
# various Epic environments (e.g. PRD, TST, RPT, DR).

#------------------------------------------------------------------------------

## General Script Logic
# - Parse through existing VG (volume group) clones to see if we need to clean
#   up any legacy clones that have aged out
# - Freeze target IRIS instance (e.g. PRD, TST, RPT, DR)
# - Take a VG clone on Nutanix AOS
# - Thaw target IRIS instance
# - Mount VG clone to a "mount" VM
# - Kick off backup job in 3rd party out-of-system backup provider
#   - e.g. Veeam

#------------------------------------------------------------------------------

## Script Usage Instructions
# 1. Allow the userid running this script passwordless ssh access
#    to the CVM (configure through Prism) and the VM hosting
#    the target VG.
# 2. Add freeze and thaw commands for the target Epic environment.
# 3. Customize Environment Configuration Variables.
# 4. Add 3rd party backup command(s).

#------------------------------------------------------------------------------

## Environment Configuration Variables
# Configure these parameters to match the target environment

# Target ODB VM Details
# - This would be a VM on the same cluster as the AHV_MOUNT_VM
# - This is used to reach into that VM and do the freeze/thaw commands
TARGET_ODB_IP="10.20.30.40"
TARGET_ODB_ACCT="epicadm"
TARGET_ODB_ENV[0]="poc"

# Nutanix AOS Cluster Details
# - Use the IP of any AOS CVM (controller VM) in the target cluster
CVM_ACCT="nutanix"
CVM_IP="10.20.30.50"

# Utility/Mount VM Details
# - This is the VM in AHV that will mount the disk clones
AHV_MOUNT_VM="epic-odb-utility1"

# Nutanix Volume Group (VG) name
# - This script assumes there is a single data volume group per backup
# - This VG may contain many individual vdisks and this script assumes that all
#   disk(s) within the Nutanix-side volume group are aggregated into
#   a Linux LVM2 volume group.
# NTNX_SOURCE_VG[0]="epic-data-vg-name-here"

# Nutanix vDisk (if not using VG's)
# - Some environments may choose to not use a Nutanix VG, e.g. TST / POC, in
#   which case a single vdisk, with a Linux LVM2 layered on top, is used.
#   The internal mechanics in AHV are slightly different in this case, so
#   instead of cloning a volume group, we'll have to clone the individual
#   disk itself. Avoid this if you can, as it works fine, but makes this
#   process much more opaque :).
VMDISK_UUID[0]="58e2606a-055c-40da-9f71-58cf55957936"

# Linux LVM Volume Group name
LVM_VG[0]="prdvg"

# Mount point for volume group
MP[0]="/mnt/backup-nfs/${TARGET_ODB_ENV[0]}"

# Number of clones to keep
# - This is useful to keep a couple of the recent clones on the system, such
#   that if rapid recovery is needed, the snapshot/clone data is already
#   on-disk.
# - The script assumes that backups will be run nightly and that keeping
#   excessive copies is unproductive, given that the delta change rate day
#   over day makes older data less and less useful.
NUM_KEEP=2

#------------------------------------------------------------------------------

## Script Helpers

PREFIX_DATE=`date +%s`
ACLI="/usr/local/nutanix/bin/acli"

# Function:  getmyvmid
#   Match this hostname to the vm_uuid
getmyvmid () {
  vmid=`sudo /usr/sbin/dmidecode | grep UUID | awk '{ print $2 }'`
  echo $vmid
}

# Function: getmyvmname
#   Match this hostname to the vm name
getmyvmname () {
  ### What host am I on?
  vmname=`ssh ${CVM_ACCT}@${CVM_IP} "${ACLI} vm.list | grep ${1} " 2> /dev/null | awk '{ print $1}'`
  echo $vmname
}
myvmid=$(getmyvmid)
myvmname=$(getmyvmname $myvmid)
echo "This VM name is " $myvmname " vm_uuid "  $myvmid

#------------------------------------------------------------------------------

## Step 1: Check for old clones and remove any over NUM_KEEP
# Clone order is based on EPOCH timestamp name prefix

# Unmount cloned file system
umount ${MP[0]}
vgremove ${LVM_VG[0]} -y

# Detach existing clones from VM
echo "Detach previous clone"
for i in `ssh ${CVM_ACCT}@${CVM_IP} "${ACLI} vg.list | grep 'copy-${TARGET_ODB_ENV[0]}' | awk '{ print $1 }'" 2> /dev/null`
do
  cnt=`ssh ${CVM_ACCT}@${CVM_IP} "${ACLI} vg.get ${i} | grep 'vm_uuid:.*${myvmid}' | wc -l " 2> /dev/null`
  #echo "Count for " $i " is " $cnt
  if (( cnt > 0 )); then
      ret=`ssh ${CVM_ACCT}@${CVM_IP} "${ACLI} vg.detach_from_vm ${i} ${myvmname} " 2> /dev/null`
      echo "Detached clone " ${i} " Ret = " $ret
  fi
done

numclone=`ssh ${CVM_ACCT}@${CVM_IP} "${ACLI} vg.list | grep [0-9].*-copy-${TARGET_ODB_ENV[0]} | wc -l" 2> /dev/null`

# Delete expired clones
echo "Current Number of Clones " $numclone " for " ${TARGET_ODB_ENV[0]}
while(( numclone >= NUM_KEEP )); do
  rmvg=`ssh ${CVM_ACCT}@${CVM_IP} "${ACLI} vg.list | /usr/bin/grep [0-9].*-copy-${TARGET_ODB_ENV[0]} | /usr/bin/sort -n | /usr/bin/head -1 | /usr/bin/sed 's/  /\:/'"  2> /dev/null`
  echo "Removing VG " ${rmvg}
  echo  ${CVM_ACCT}@${CVM_IP} "/usr/bin/echo yes | ${ACLI} vg.delete ${rmvg}"
  ssh ${CVM_ACCT}@${CVM_IP} "/usr/bin/echo yes | ${ACLI} vg.delete ${rmvg}"
  numclone=`ssh ${CVM_ACCT}@${CVM_IP} ${ACLI} vg.list | grep [0-9].*-copy-${TARGET_ODB_ENV[0]} | wc -l`
done


#------------------------------------------------------------------------------

## Step 2: Freeze target ODB
ssh ${TARGET_ODB_ACCT}@${TARGET_ODB_IP} "echo -n "Freezing ${TARGET_ODB_ENV[0]}: " ; /epic/${TARGET_ODB_ENV[0]}/bin/instfreeze"
echo ""

#------------------------------------------------------------------------------

## Step 3: Clone the VG
# echo "Creating new clone " ${PREFIX_DATE}-copy-${TARGET_ODB_ENV[0]}
# ssh ${CVM_ACCT}@${CVM_IP} ${ACLI} vg.clone ${PREFIX_DATE}-copy-${TARGET_ODB_ENV[0]} clone_from_vg=${NTNX_SOURCE_VG[0]}

# Special Case: single vDisk (non-VG) cloning
# - We'll clone the vdisk attached to the environment into a VG, which
#   allows us to treat the rest of the logic in this script just like we would
#   if the original setup was with a VG.
# - To do this, create a tmp volumegroup first, then clone the vdisk into that
#   temp vg. This will be used to hold the vmdisk clones.
# - Note: this is here for special cases only, try to avoid this if you can
#   and use VG's everywhere instead, even for single vdisks in TST, POC, etc.
ssh ${CVM_ACCT}@${CVM_IP} "${ACLI} vg.create \
  ${PREFIX_DATE}-copy-${TARGET_ODB_ENV[0]}"
ssh ${CVM_ACCT}@${CVM_IP} "${ACLI} vg.disk_create \
  ${PREFIX_DATE}-copy-${TARGET_ODB_ENV[0]} \
  clone_from_vmdisk=${VMDISK_UUID[0]}"

#------------------------------------------------------------------------------

## Step 4: Thaw target ODB
ssh ${TARGET_ODB_ACCT}@${TARGET_ODB_IP} "echo -n "Thawing ${TARGET_ODB_ENV[0]}: " ; /epic/${TARGET_ODB_ENV[0]}/bin/instthaw"
echo ""

#------------------------------------------------------------------------------

## Step 5: Mount the clone
# Attach new clone
echo "Attach " ${PREFIX_DATE}-copy-${TARGET_ODB_ENV[0]}
ssh ${CVM_ACCT}@${CVM_IP} "${ACLI} vg.attach_to_vm ${PREFIX_DATE}-copy-${TARGET_ODB_ENV[0]} ${AHV_MOUNT_VM}"

# Clean up LVM metadata
pvscan --cache

# Get device name
dev_path=`/usr/sbin/lvdisplay ${LVM_VG[0]} | awk '{ if( $2 == "Path" ) print $3 }'`

# Mount the File System
/usr/bin/mount $dev_path ${MP[0]}
df
ret=`/usr/bin/df | grep "${MP[0]}" | wc -l`
if(( ret == 1 )); then
  echo "Backup file system ${MP[0]} is ready."
else
  echo "Backup file system ${MP[0]} did not mount properly"
  exit
fi

#------------------------------------------------------------------------------

## Step 6: Kick off 3rd party out-of-system backup
echo "Kick off backup for " ${PREFIX_DATE}-copy-${TARGET_ODB_ENV[0]]}

# Endpoint URL for login action
veeamUsername="EMUsername" # If using domain based account, enter UPN (e.g. user@domain.com)
veeamPassword="EMPassword"
veeamAuth=$(echo -ne "$veeamUsername:$veeamPassword" | base64);
veeamRestServer="EMServer" #IP Address or FQDN of Enterprise Manager server
veeamRestPort="9398"
veeamSessionId=$(curl -X POST "https://$veeamRestServer:$veeamRestPort/api/sessionMngr/?v=latest" -H "Authorization:Basic $veeamAuth" -H "Content-Length: 0" -H "Accept: application/json" -k -v | awk 'NR==1{sub(/^\xef\xbb\xbf/,"")}1' | jq --raw-output ".SessionId")
veeamXRestSvcSessionId=$(echo -ne "$veeamSessionId" | base64);
veeamJobId="763797f3-391c-46c8-aa81-83d04f534396"

# Rubrik
# https://rubrikinc.github.io/api-doc-v1-6.0/#section/Authentication/Authentication-session
rubrikUsername=""
rubrikPassword=""
rubrikAuth=$(echo -ne "$rubrikUsername:$rubrikPassword" | base64); # maybe not needed? -u flags the string in the curl command
rubrikRestServer="" # IP
rubrikRestPort=""
# curl -k -u admin:pass -X POST "https://$cluster_address/api/v1/session"
token_id=curl -k -u admin:pass -X POST "https://$cluster_address/api/v1/session" | jq '.token'
curl -k -H "Authorization: Bearer $token_id" -X GET "https://$cluster_address/api/v1/cluster/me"



rubrikSessionId=$()

# Rubrik trigger backup
# check in rest api explorer how to manage ahv vms
# https://rubrikinc.github.io/api-doc-v1-6.0/#section/Virtual-machines/Snapshot-management
# Get VM "https://$cluster_address/api/v1/vmware/vm"
vm_id=...
# Creating on demand snapshot
request_id=curl -X POST "https://$cluster_address/api/v1/vmware/vm/$vm_id/snapshot" # jq '.id'
# Check status
curl -X GET "https://$cluster_address/api/v1/vmware/vm/request/$request_id" | jq '.status' # = SUCCEEDED, use while loop



# Query Job
veeamEMJobUrl="https://$veeamRestServer:$veeamRestPort/api/nas/jobs/$veeamJobId?format=Entity"
veeamEMJobDetailUrl=$(curl -X GET "$veeamEMJobUrl" -H "Accept:application/json" -H "X-RestSvcSessionId: $veeamXRestSvcSessionId" -H "Cookie: X-RestSvcSessionId=$veeamXRestSvcSessionId" -H "Content-Length: 0" -k -v | awk 'NR==1{sub(/^\xef\xbb\xbf/,"")}1')

# Start Job
veeamEMStartUrl="https://$veeamRestServer:$veeamRestPort/api/nas/jobs/$veeamJobId/start"
veeamEMResultUrl=$(curl -X POST "$veeamEMStartUrl" -H "Accept:application/json" -H "X-RestSvcSessionId: $veeamXRestSvcSessionId" -H "Cookie: X-RestSvcSessionId=$veeamXRestSvcSessionId" -H "Content-Length: 0" -k -v | awk 'NR==1{sub(/^\xef\xbb\xbf/,"")}1')

# Capture & Display Results
veeamJobName=$(echo "$veeamEMJobDetailUrl" | jq --raw-output ".Name")
veeamTaskId=$(echo "$veeamEMResultUrl" | jq --raw-output ".TaskId")
veeamState=$(echo "$veeamEMResultUrl" | jq --raw-output ".State")
veeamOperation=$(echo "$veeamEMResultUrl" | jq --raw-output ".Operation")

#------------------------------------------------------------------------------

# TODOs
# - squash Scott's reg_with_cvm and reg_with_uvm functions to automatically
#   handle getting passwordless SSH setup.
# - add error handling
