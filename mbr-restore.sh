#!/bin/sh

if [ -z "$1" ] || [ -z "$2" ]; then
  echo "ERROR: Bad or missing arguments"
  echo "Usage: mbr_update.sh [source_file] [target_device]" >&2
  exit 1
fi

SOURCE_FILE="$1"
TARGET_DEVICE="${2#/dev/}"

if [ ! -f "$SOURCE_FILE" ]; then
  echo "ERROR: Source file ($SOURCE_FILE) not found!" >&2
  exit 2
fi

if [ ! -b "$SOURCE_FILE" ]; then
  echo "ERROR: Target device ($TARGET_DEVICE) not found!" >&2
  exit 3
fi

# Update track0, while preserving current partition table
dd if="$SOURCE_FILE" of=/dev/$TARGET_DEVICE bs=446 count=1 && dd if="$SOURCE_FILE" of=/dev/$TARGET_DEVICE seek=512 skip=512
