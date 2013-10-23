#!/bin/sh

# Auto remove pagefile.sys & hiberfil.sys from NTFS Windows partitions
IFS=' '
for PART_NODEV in $BACKUP_PARTITIONS; do
  TYPE=`blkid -s TYPE -o value "/dev/${PART_NODEV}"`
  if [ "$TYPE" = "ntfs" ]; then
    if mkdir -p /mnt/temp && ntfs-3g "/dev/${PART_NODEV}" /mnt/temp; then
      if [ -f "/mnt/temp/hiberfil.sys" ]; then
        echo "* Remove /dev/$PART_NODEV/hiberfil.sys"
        rm /mnt/temp/hiberfil.sys
      fi
      if [ -f "/mnt/temp/pagefile.sys" ]; then
        echo "* Remove /dev/$PART_NODEV/pagefile.sys"
        rm /mnt/temp/pagefile.sys
      fi
    fi
    
    umount /mnt/temp
  fi
done
