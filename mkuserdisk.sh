# Auto create d: ntfs drive (user disk).

####################
# Global variables #
####################
# Globals sourced from main script: CLEAN, TARGET_DEVICES

# The primary partition number to use for the user partition (with Win7, 1 and 2 are used by the OS)
USER_PART_ID="3"

USER_DISK_NODEV=""
USER_DISK_WIPE=0

#############
# Functions #
#############

# Function to detect whether a device has a GPT partition table
gpt_detect()
{
  if sfdisk -d "$1" 2>/dev/null |grep -q -E -i -e '[[:blank:]]Id=ee' -e '^Partition Table: gpt' -e '^label: gpt'; then
    return 0 # GPT found
  else
    return 1 # GPT not found
  fi

#  if gdisk -l "$1" |grep -q 'GPT: not present'; then
#    return 1 # GPT not found
#  else
#    return 0 # GPT found
#  fi
}


# Arguments: $1 = DISK, $2 = Partition ID, $3 = Start with empty partition table(1)
mkud_create_user_dos_partition()
{
  local DOS_DISK="$1"
  local DOS_PART_ID="$2"
  local DOS_PART="${DOS_DISK}${DOS_PART_ID}"
  local EMPTY_PARTITION_TABLE="$3"
  local FDISK_CMD=""

  # TODO?: Use parted -s and auto detect USER_PART_ID
  if [ $EMPTY_PARTITION_TABLE -eq 1 ]; then
    echo "* Creating new (empty) DOS partition"
    # Empty partition table"
    FDISK_CMD="o
n
p
$DOS_PART_ID


t
7
w
"
  else
    echo "* Adding user partition to (existing) DOS partition"
    FDISK_CMD="n
p
$DOS_PART_ID


t
$DOS_PART_ID
7
w
"
  fi

  # Create NTFS partition:
  echo "* Creating user NTFS DOS partition $DOS_PART"
  if ! echo "$FDISK_CMD" |fdisk $DOS_DISK >/dev/null; then
    return 1
  fi

  return 0
}


# Arguments: $1 = DISK, $2 = Partition ID
mkud_create_user_gpt_partition()
{
  local GPT_DISK="$1"
  local GPT_PART_ID="$2"
  local GPT_PART="${GPT_DISK}${GPT_PART_ID}"
  local EMPTY_PARTITION_TABLE="$3"
  local GDISK_CMD=""

  # TODO?: Use parted -s and auto detect PART_ID
  if [ $EMPTY_PARTITION_TABLE -eq 1 ]; then
    echo "* Creating new (empty) GPT partition"
    # Empty partition table"
    GDISK_CMD="o
y
n
$GPT_PART_ID


0700
w
y
"
  else
    echo "* Adding user partition to (existing) GPT partition"
    GDISK_CMD="n
$GPT_PART_ID


0700
w
y
"
  fi

  # Create NTFS partition:
  echo "* Creating user NTFS GPT partition $GPT_PART"

  if ! echo "$GDISK_CMD" |gdisk $GPT_DISK >/dev/null; then
    return 1
  fi

  return 0
}


# Arguemtns: $1 = DISK_NODEV, $2 = partition id, $3 = fileystem label, $4 = (wipe + ) repartition disk(1) or not (0)
mkud_create_user_filesystem()
{
  local TARGET_DISK_NODEV="$1"
  local TARGET_PART_ID="$2"
  local TARGET_PART_LABEL="$3"
  local REPARTITION_DISK="$4"
  local TARGET_DISK="/dev/${TARGET_DISK_NODEV}"
  local TARGET_PART="${TARGET_DISK}${TARGET_PART_ID}"

  # TODO: Skip the block below if our target disk already *exactly* matches?!
  local PARTITIONS_FOUND="$(get_partitions $TARGET_DISK)"
  if ! echo "$PARTITIONS_FOUND" |grep -q "${TARGET_DISK_NODEV}${TARGET_PART_ID}$" || [ $REPARTITION_DISK -eq 1 ]; then
    # If user partition is on the same device as the images, check that it does not exist already
    if [ ! -e $TARGET_PART -o $REPARTITION_DISK -eq 1 ]; then
      # Detect GPT. Always use GPT on an empty disk since size may be > 2TB
      if [ $REPARTITION_DISK -eq 1 ] || gpt_detect $TARGET_DISK; then
        mkud_create_user_gpt_partition $TARGET_DISK $TARGET_PART_ID $REPARTITION_DISK
      else
        mkud_create_user_dos_partition $TARGET_DISK $TARGET_PART_ID $REPARTITION_DISK
      fi
    else
      echo "* Skipping creation of NTFS partition $TARGET_PART since it already exists"
    fi

    if ! partprobe $TARGET_DISK; then
      printf "\033[40m\033[1;31mWARNING: (Re)reading the partition table failed!\nPress enter to continue or CTRL-C to abort...\n\033[0m" >&2
      read
      echo ""
    fi

    echo "* Creating user NTFS filesystem on $TARGET_PART with label \"$TARGET_PART_LABEL\""
    if mkntfs -L $TARGET_PART_LABEL -Q $TARGET_PART; then
      if mkdir -p /mnt/windows && ntfs-3g "$TARGET_PART" /mnt/windows; then
        mkdir "/mnt/windows/My Documents"
        mkdir "/mnt/windows/Downloads"
        mkdir "/mnt/windows/temp"
#        mkdir "/mnt/windows/Program Files"

        umount /mnt/windows
      else
        printf "\033[40m\033[1;31mWARNING: Mounting NTFS partition $TARGET_PART failed (disk in use?!)\n\033[0m" >&2
      fi
    else
      printf "\033[40m\033[1;31mERROR: Creating NTFS filesystem on $TARGET_PART failed!\033[0m\n" >&2
    fi
  else
    echo "* Skipping creation of NTFS filesystem on $TARGET_PART since it already exists"
  fi
}


mkud_select_disk()
{
  # Check which partitions we can use for the user partiton, we ignore mounted ones
  local FIND_DISKS=""
  unset IFS
  for DISK in `cat /proc/partitions |grep -E '[sh]d[a-z]$' |awk '{ print $4 }' |sed s,'^/dev/',,`; do
    # Ignore disks with swap/mounted partitions
    if grep -E -q "^/dev/${DISK}p?[0-9]+" /etc/mtab; then
      echo "* NOTE: Ignoring disk with mounted partitions /dev/$DISK" >&2
    elif ! grep -E -q "^/dev/${PART}p?[0-9]+" /proc/swaps; then
      FIND_DISKS="${FIND_DISKS}${FIND_DISKS:+ }$DISK"
    fi
  done

  # Check all disks
  IFS=' '
  for DISK_NODEV in $FIND_DISKS; do
    # With more than one disk assume user partition will be on the (first) other disk than the OS
    if ! echo "$TARGET_DEVICES" |grep -q -E "(^| |/)$DISK_NODEV( |$)"; then
      USER_DISK_NODEV="" # Reset, in case it was set below
      # Check for partitions on disk
      PARTITIONS_FOUND="$(get_partitions /dev/$DISK_NODEV)"
      if [ -n "$PARTITIONS_FOUND" ]; then
        if [ $CLEAN -eq 1 ]; then
          printf "\033[40m\033[1;31m* WARNING: Disk /dev/$DISK_NODEV already contains partitions!\n\033[0m" >&2
          if ! get_user_yn "  Wipe (repartition + format) and format as (additional) user disk"; then
            continue; # Try next
          fi
        else
          echo "* NOTE: Extra disk /dev/$DISK_NODEV already contains partitions, ignoring it"
          continue; # Try next
        fi
      fi
      USER_DISK_WIPE=1
      USER_DISK_NODEV="$DISK_NODEV"
      break; # We're done
    elif [ -z "$USER_DISK_NODEV" ]; then
      USER_DISK_NODEV="$DISK_NODEV" # Default to the first disk in the list
    fi
  done

#    TODO: User selection
#    echo "Multiple disks found:"
#    echo "$FIND_DISKS"
}


############
# Mainline #
############

# Get $USER_DISK_NODEV:
mkud_select_disk;

if [ -z "$USER_DISK_NODEV" ]; then
  echo "WARNING: No (suitable) disk found for user partition!" >&2
else
  # In principle we should never have to wipe + repartition(0) the OS disk
  # as this should already be done while restoring the images
  mkud_create_user_filesystem "$USER_DISK_NODEV" "$USER_PART_ID" "USER" $USER_DISK_WIPE

  # Add the disk to restore-image script's target list so its partitions get listed when done
  if ! echo "$TARGET_DEVICES" |grep -q -E "(^| )/dev/$USER_DISK_NODEV( |$)"; then
    TARGET_DEVICES="$TARGET_DEVICES /dev/$USER_DISK_NODEV"
  fi
fi
