# Auto create d: drive (user disk). Note that this script only works for a
# restore to a single disk!

####################
# Global variables #
####################

# The primary partition number to use for the user partition (with Win7, 1 and 2 are used by the OS)
USER_PART_ID="3"

USER_DISK=""
USER_DISK_NODEV=""
USER_DISK_ON_OTHER_DEVICE=0
EMPTY_PARTITION_TABLE=0

#############
# Functions #
#############


mkud_create_user_dos_partition()
{
  local PART_ID="$USER_PART_ID"
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

  # Create NTFS partition:
  echo "* Creating user NTFS DOS partition $USER_PART"
  if ! echo "$FDISK_CMD" |fdisk $USER_DISK >/dev/null; then
    return 1
  fi
  
  return 0
}


mkud_create_user_gpt_partition()
{
  local PART_ID="$USER_PART_ID"
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

  # Create NTFS partition:
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

  local PARTITIONS_FOUND=`get_disk_partitions "${USER_DISK_NODEV}"`
  if ! echo "$PARTITIONS_FOUND" |grep -q "${USER_DISK_NODEV}${PART_ID}$" || [ $CLEAN -eq 1 ]; then
    # Automatically handle cases where we have 2 harddisks: one for the OS (Eg. ssd) and one for user data and empty disks
    if [ "$CLEAN" = "1" -a $USER_DISK_ON_OTHER_DEVICE -eq 1 ] || [ -z "$PARTITIONS_FOUND" ]; then
      EMPTY_PARTITION_TABLE=1
    fi

    # If user partition is on the same device as the images, check that it does not exist already
    if [ ! -e $USER_PART -o $EMPTY_PARTITION_TABLE -eq 1 ]; then
      # Detect GPT
      if sfdisk -d $USER_DISK 2>/dev/null |grep -q -E -i '[[:blank:]]Id=ee'; then
        mkud_create_user_gpt_partition;
      else
        mkud_create_user_dos_partition;
      fi
    else
      echo "* Skipping creation of NTFS partition $USER_PART since it already exists"
    fi

    if ! partprobe /dev/$TARGET_NODEV; then
      printf "\033[40m\033[1;31mWARNING: (Re)reading the partition table failed!\nPress enter to continue or CTRL-C to abort...\n\033[0m" >&2
      read
      echo ""
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
  for DISK in `cat /proc/partitions |grep -E '[sh]d[a-z]$' |awk '{ print $4 }' |sed s,'^/dev/',,`; do
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
        USER_DISK_ON_OTHER_DEVICE=1
        break;
      fi
    done

#    TODO: User selection
#    echo "Multiple disks found:"
#    echo "$FIND_DISKS"
  else
    # Only one disk, use that as default
    USER_DISK_NODEV="$FIND_DISKS"
    USER_DISK_ON_OTHER_DEVICE=0
  fi
}


############
# Mainline #
############

# Get $USER_DISK_NODEV:
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
