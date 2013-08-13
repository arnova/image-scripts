#!/bin/sh

# Auto create d: drive (user disk). Note that this script only works for a
# restore to a single disk!

# The primary partition number to use for the user partition (with Win7, 1 and 2 are used by the OS)
USER_PART_ID="3"

mkud_get_disks()
{
  cat /proc/partitions |grep -E '[sh]d[a-z]$' |awk '{ print $4 }' |sed s,'^/dev/',,
}


mkud_get_partitions_with_size()
{
  cat /proc/partitions |sed -e '1,2d' -e 's,^/dev/,,' |awk '{ print $4" "$3 }'
}


mkud_get_partitions()
{
  mkud_get_partitions_with_size |awk '{ print $1 }'
}


mkud_create_user_partition()
{
  local USER_DISK_NODEV=$1
  local USER_DISK="/dev/$1"
  local PART_ID=$2
  local USER_PART="${USER_DISK}${PART_ID}"

  local EMPTY_PARTITION_TABLE=0

  if [ "$CLEAN" = "1" ] && ! echo "$TARGET_DEVICES" |grep -q -e " $USER_DISK " -e "^$USER_DISK " -e " $USER_DISK$" && ! echo "$TARGET_NODEV" |grep -q -e " $USER_DISK_NODEV " -e "^$USER_DISK_NODEV " -e " $USER_DISK_NODEV$"; then
    EMPTY_PARTITION_TABLE=1
  fi

  if ! mkud_get_partitions |grep -q "${USER_DISK_NODEV}${PART_ID}" || [ $EMPTY_PARTITION_TABLE -eq 1 ]; then
    echo "* Creating user NTFS partition $USER_PART"

    # Create NTFS partition:
    local FDISK_CMD=""

    if [ $EMPTY_PARTITION_TABLE -eq 1 ]; then
      # Empty partition table"
      FDISK_CMD="o
                 n
                 p
                 $PART_ID


                 t
                 7
                 w
                "
    else
      FDISK_CMD="n
p
$PART_ID


t
$PART_ID
7
w
"
    fi

    echo "$FDISK_CMD" |fdisk $USER_DISK >/dev/null

    if ! sfdisk -R $USER_DISK; then
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
  # Check which partitions to backup, we ignore mounted ones
  local FIND_DISKS=""
  unset IFS
  for DISK in `mkud_get_disks`; do
    # Ignore disks with swap/mounted partitions
    if ! grep -E -q "^/dev/${DISK}p?[0-9]+" /etc/mtab && ! grep -E -q "^/dev/${PART}p?[0-9]+" /proc/swaps; then
      FIND_DISKS="${FIND_DISKS}${FIND_DISKS:+ }$DISK"
    fi
  done

  # With more than one disk assume user partition will be on another disk than the OS
  if [ $(echo "$FIND_DISKS" |wc -w) -gt 1 ]; then
    IFS=' '
    for DISK in $FIND_DISKS; do
      if [ "$DISK" != "$TARGET_NODEV" ] && ! echo "$TARGET_DEVICES" |grep -q -e " $DISK " -e "^$DISK " -e " $DISK$"; then
        USER_DISK_NODEV="$DISK"

        # Add the disk to restore-image script's target list
        TARGET_DEVICES="$TARGET_DEVICES /dev/$DISK"

        break;
      fi
    done

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
  mkud_create_user_partition $USER_DISK_NODEV $USER_PART_ID
fi
