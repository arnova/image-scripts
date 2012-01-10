#!/bin/sh

# Auto create d: drive (user disk). Note that this script only works for a
# restore to a single disk!

# The primary partition number to use for the user partition:
USER_PART_ID="3"

if [ -z "$TARGET_NODEV" ]; then
  TARGET_NODEV="$1"
fi

if [ -z "$TARGET_NODEV" ]; then
  echo "Partition not specified" >&2
else
  USER_PART="${TARGET_NODEV}${USER_PART_ID}"
  if ! cat /proc/partitions |awk '{ print $NF }' |sed s,'^/dev/','', |grep -q "$USER_PART$" || [ "$CLEAN" = "1" ]; then
    echo "* Creating user partition on \"/dev/$TARGET_NODEV\""
    # Create NTFS partition:
    printf "n\np\n${USER_PART_ID}\n\n\nt\n${USER_PART_ID}\n7\nw\n" |fdisk /dev/$TARGET_NODEV >/dev/null

    if ! partprobe /dev/$TARGET_NODEV; then
      printf "\033[40m\033[1;31mWARNING: (Re)reading the partition table failed!\nPress enter to continue or CTRL-C to abort...\n\033[0m" >&2
      read
      echo ""
    fi

    echo "* Creating user NTFS filesystem on \"/dev/$USER_PART\""
    if mkntfs -L USER -Q "/dev/$USER_PART"; then
      mkdir -p /mnt/windows &&
      ntfs-3g "/dev/$USER_PART" /mnt/windows &&
      mkdir "/mnt/windows/temp" &&
      mkdir "/mnt/windows/My Documents" &&
      mkdir "/mnt/windows/Program Files" &&
      mkdir "/mnt/windows/Downloads"
      
      umount /mnt/windows
    else
      printf "\033[40m\033[1;31mERROR: Creating NTFS filesystem on /dev/$USER_PART failed!\033[0m\n" >&2
    fi
  else
    echo "* Skipping creation of NTFS filesystem on \"/dev/$USER_PART\" since it already exists"
  fi
fi

