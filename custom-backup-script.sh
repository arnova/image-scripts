#!/bin/sh

# Auto remove pagefile.sys & hibernate.sys from NTFS Windows partitions
IFS=' '
for PART_NODEV in $BACKUP_PARTITIONS; do
  TYPE=`blkid -s TYPE -o value "/dev/${PART_NODEV}"`
  if [ "$TYPE" = "ntfs" ]; then
    if mkdir -p /mnt/windows && ntfs-3g "/dev/${PART_NODEV}" /mnt/windows && cd /mnt/windows; then
      printf "* /dev/$PART_NODEV: "
      rm -fv hiberfil.sys
#      rm -fv pagefile.sys
    fi

    umount /mnt/windows
  fi
done

