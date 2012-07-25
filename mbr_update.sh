#!/bin/sh

# Get target device from 1st argument and remove /dev/
TARGET_DEVICE=`echo "$1" |sed s,'/dev/',,g`

if [ -z "$TARGET_DEVICE" ]; then
  echo "Usage: mbr_update.sh {target_device}"
  exit 1
fi

# Update track0, while preserving current partition table
dd if=track0.sda of=/dev/$TARGET_DEVICE bs=446 count=1 && dd if=track0.sda of=/dev/$TARGET_DEVICE seek=512 skip=512
