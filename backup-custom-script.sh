#!/bin/sh

# Auto remove pagefile.sys & hibernate.sys from NTFS Windows partitions
IFS=' '
for PART_NODEV in $BACKUP_PARTITIONS; do
  local TYPE=`blkid -s TYPE -o value "/dev/${PART_NODEV}"`
  if [ "$TYPE" = "ntfs" ]; then
    mkdir -p /mnt/windows &&
    ntfs-3g "$PART_NODEV" /mnt/windows
 
    rm -fv /mnt/windows/hiberfile.sys
    rm -fv /mnt/windows/pagefile.sys

    umount /mnt/windows
  fi
done
