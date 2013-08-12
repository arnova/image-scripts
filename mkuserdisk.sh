#!/bin/sh

# Auto create d: drive (user disk). Note that this script only works for a
# restore to a single disk!

# The primary partition number to use for the user partition (with Win7, 1 and 2 are used by the OS)
USER_PART_ID="3"

mkud_get_disks()
{
  cat /proc/partitions |grep -E '[sh]d[a-z]$' |awk '{ print $4 }' |sed s,'^/dev/',,
}


mkud_create_user_partition()
{
  local USER_DISK=$1
  local PART_ID=$2
  local USER_PART="${USER_DISK}${PART_ID}"

  if ! get_partitions |grep -q "$(echo "$USER_PART" |sed s,'^/dev/',,)$" || [ "$CLEAN" = "1" ]; then
    echo "* Creating user NTFS partition $USER_PART"
    # Create NTFS partition:
    printf "n\np\n${PART_ID}\n\n\nt\n${PART_ID}\n7\nw\n" |fdisk $USER_DISK >/dev/null

    if ! partprobe $USER_DISK; then
      printf "\033[40m\033[1;31mWARNING: (Re)reading the partition table failed!\nPress enter to continue or CTRL-C to abort...\n\033[0m" >&2
      read
    fi

    echo ""
    echo "* Creating user NTFS filesystem on $USER_PART"
    if mkntfs -L USER -Q "$USER_PART"; then
      mkdir -p /mnt/windows &&
      ntfs-3g "$USER_PART" /mnt/windows &&
      mkdir "/mnt/windows/temp" &&
      mkdir "/mnt/windows/My Documents" &&
      mkdir "/mnt/windows/Program Files" &&
      mkdir "/mnt/windows/Downloads"
      
      umount /mnt/windows
    else
      printf "\033[40m\033[1;31mERROR: Creating NTFS filesystem on $USER_PART failed!\033[0m\n" >&2
    fi
  else
    echo "* Skipping creation of NTFS filesystem on $USER_PART since it already exists"
  fi
}


mkud_select_disk()
{
  local FIND_DISKS=`get_disks_local`

  if [ $(echo "$FIND_DISKS" |wc -l) -gt 1 ]; then
    # Use last disk by default
    USER_DISK_NODEV=`echo "$FIND_DISKS" |tail -n1`
    
#    TODO: User selection
#    echo "Multiple disks found:"
#    echo "$FIND_DISKS"
  else
    # Only one disk, use that as default
    USER_DISK_NODEV="$FIND_DISKS"
  fi
}

############
# Mainline #
############

# Old way:
#if [ -n "$TARGET_DEVICES" ]; then
#  TARGET_DEVICE=`echo "$TARGET_DEVICES" |cut -f1 -d' '`
#elif [ -n "$TARGET_NODEV" ]; then
#  TARGET_DEVICE="/dev/$TARGET_NODEV"
#elif [ -n "$1" ]; then
#  TARGET_DEVICE="$1"
#fi

USER_DISK_NODEV=""

# Get $USER_DISK_NODEV & $USER_PART_ID:
mkud_select_disk;

if [ -z "$USER_DISK_NODEV" ]; then
  echo "WARNING: No (suitable) disk found for user partition!" >&2
else
  create_user_partition "/dev/$USER_DISK_NODEV" $USER_PART_ID
fi
