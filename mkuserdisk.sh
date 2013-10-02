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


mkud_create_user_dos_partition()
{
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

  echo "* Creating user NTFS DOS partition $USER_PART"
  if ! echo "$FDISK_CMD" |fdisk $USER_DISK >/dev/null; then
    return 1
  fi
  
  return 0
}


mkud_create_user_gpt_partition()
{
  # Create NTFS partition:
  local GDISK_CMD=""

  if [ $EMPTY_PARTITION_TABLE -eq 1 ]; then
    # Empty partition table"
    GDISK_CMD="o
               n


               t
               0700
               w
              "
  else
    GDISK_CMD="n
               $PART_ID


               t
               $PART_ID
               0700
               w
              "
  fi

  echo "* Creating user NTFS GPT partition $USER_PART"
  
  if ! echo "$GDISK_CMD" |gdisk $USER_DISK >/dev/null; then
    return 1
  fi
  
  return 0
}


mkud_create_user_filesystem()
{
  local PART_ID=$USER_PART_ID
  local USER_PART="${USER_DISK}${PART_ID}"

  local PARTITIONS_FOUND=`mkud_get_partitions |grep -E -x "${USER_DISK_NODEV}p?[0-9]+"`
  if ! echo "$PARTITIONS_FOUND" |grep -q "${USER_DISK_NODEV}${PART_ID}" || [ $CLEAN -eq 1 ]; then
    local EMPTY_PARTITION_TABLE=0

    # Automatically handle cases where we have 2 harddisks: one for the OS (Eg. ssd) and one for user data
    if [ "$CLEAN" = "1" ] && [ -n "$TARGET_DEVICES" -o -n "$TARGET_NODEV" ] && \
       ! echo "$TARGET_DEVICES" |grep -q -e " $USER_DISK " -e "^$USER_DISK " -e " $USER_DISK$" && \
       ! echo "$TARGET_NODEV" |grep -q -e " $USER_DISK_NODEV " -e "^$USER_DISK_NODEV " -e " $USER_DISK_NODEV$"; then
      EMPTY_PARTITION_TABLE=1
    fi

    # Check whether target device is (already) empty
    if [ -z "$PARTITIONS_FOUND" ]; then
      EMPTY_PARTITION_TABLE=1
    fi

    # Detect GPT
    if sfdisk -d $USER_DISK 2>/dev/null |grep -q -i 'Id=ee$'; then
      mkud_create_user_gpt_partition;
    else
      mkud_create_user_dos_partition;
    fi

    if ! sfdisk -R $USER_DISK; then
      printf "\033[40m\033[1;31mWARNING: (Re)reading the partition table failed!\nPress enter to continue or CTRL-C to abort...\n\033[0m" >&2
      read
    fi

    echo "* Creating user NTFS filesystem on $USER_PART"
    if mkntfs -L USER -Q "$USER_PART"; then
      if mkdir -p /mnt/windows && ntfs-3g "$USER_PART" /mnt/windows; then
        mkdir "/mnt/windows/My Documents"
        mkdir "/mnt/windows/Downloads"
        mkdir "/mnt/windows/temp"
#        mkdir "/mnt/windows/Program Files"
      fi

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
      if [ "$DISK" != "$TARGET_NODEV" ] && ! echo "$TARGET_DEVICES" |grep -q -e " ${DISK} " -e "^${DISK} " -e "^${DISK}$" -e " ${DISK}$"; then
        USER_DISK_NODEV="$DISK"
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
USER_DISK_NODEV=""

# Get $USER_DISK_NODEV & $USER_PART_ID:
mkud_select_disk;

if [ -z "$USER_DISK_NODEV" ]; then
  echo "WARNING: No (suitable) disk found for user partition!" >&2
else
  USER_DISK="/dev/${USER_DISK_NODEV}"
  mkud_create_user_filesystem;

  # Add the disk to restore-image script's target list so its partitions get listed when done
  if ! echo "$TARGET_DEVICES" |grep -q -e " ${USER_DISK} " -e "^${USER_DISK} " -e "^${USER_DISK}$" -e " ${USER_DISK}$"; then
    TARGET_DEVICES="$TARGET_DEVICES $USER_DISK"
  fi
fi
