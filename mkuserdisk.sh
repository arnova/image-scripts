#!/bin/sh

# Auto create d: drive (user disk). Note that this script only works for a
# restore to a single disk!
if [ -z "$TARGET_NODEV" ]; then
  TARGET_NODEV="$1"
fi

if [ -z "$TARGET_NODEV" ]; then
  echo "Partition not specified" >&2
else
  USER_PART="$TARGET_NODEV""2"
  if ! cat /proc/partitions |awk '{ print $NF }' |sed s,'^/dev/','', |grep -q "$USER_PART$" || [ "$CLEAN" = "1" ]; then
    echo "* Creating user partition on \"/dev/$TARGET_NODEV\""
    # NTFS partition on 2nd primary:
    printf "n\np\n2\n\n\nt\n2\n7\nw\n" |fdisk /dev/$TARGET_NODEV    
    
    # HACK: Somehow newer fdisks + kernels don't properly reread the partition table fast enough
    #       causing mkntfs to fail. This nasty trick seems to force it
    sfdisk -d /dev/$TARGET_NODEV |sfdisk --force /dev/$TARGET_NODEV
    
    # Run partprobe, just in case
    partprobe /dev/$TARGET_NODEV
    
    echo "* Creating user NTFS filesystem on \"/dev/$USER_PART\""
    mkntfs -L user -Q "/dev/$USER_PART" &&
    mkdir -p /mnt/windows &&
    ntfs-3g "/dev/$USER_PART" /mnt/windows &&
    mkdir "/mnt/windows/temp" &&
    mkdir "/mnt/windows/My Documents" &&
    mkdir "/mnt/windows/Program Files"
    
    umount /mnt/windows
  else
    echo "* Skipping creation of NTFS filesystem on \"/dev/$USER_PART\" since it already exists"
  fi
fi

