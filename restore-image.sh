#!/bin/bash

MY_VERSION="3.11c"
# ----------------------------------------------------------------------------------------------------------------------
# Image Restore Script with (SMB) network support
# Last update: February 12, 2015
# (C) Copyright 2004-2015 by Arno van Amersfoort
# Homepage              : http://rocky.eld.leidenuniv.nl/
# Email                 : a r n o v a AT r o c k y DOT e l d DOT l e i d e n u n i v DOT n l
#                         (note: you must remove all spaces and substitute the @ and the . at the proper locations!)
# ----------------------------------------------------------------------------------------------------------------------
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# version 2 as published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
# ----------------------------------------------------------------------------------------------------------------------

DEFAULT_CONF="$(dirname $0)/image.cnf"

##################
# Define globals #
##################
SUCCESS=""
FAILED=""

# Reset global, used by other functions later on:
TARGET_DEVICES=""
  
# Global used later on when restoring partition-tables etc.
DEVICE_FILES=""

SEP=':'
EOL='
'

do_exit()
{
  echo ""
  echo ""

  # Auto unmount?
  if [ "$AUTO_UNMOUNT" = "1" ] && [ -n "$MOUNT_DEVICE" ] && grep -q " $IMAGE_ROOT " /etc/mtab; then
    # Go to root else we can't umount
    cd /
    
    # Umount our image repo
    umount -v "$IMAGE_ROOT"
  fi
  exit $1
}


ctrlc_handler()
{
  stty intr ^C    # Back to normal
  do_exit 1       # Yep, I meant to do that... Kill/hang the shell.
}


get_user_yn()
{
  printf "$1 "

  read answer_with_case
  
  answer=`echo "$answer_with_case" |tr A-Z a-z`

  if [ "$answer" = "y" -o "$answer" = "yes" ]; then
    return 0
  fi

  if [ "$answer" = "n" -o "$answer" = "no" ]; then
    return 1
  fi

  # Fallback to default
  if [ "$2" = "y" ]; then
    return 0
  else
    return 1
  fi
}


human_size()
{
  echo "$1" |awk '{
    SIZE=$1
    TB_SIZE=(SIZE / 1024 / 1024 / 1024 / 1024)
    if (TB_SIZE > 1.0)
    {
      printf("%.2f TiB\n", TB_SIZE)
    }
    else
    {
      GB_SIZE=(SIZE / 1024 / 1024 / 1024)
      if (GB_SIZE > 1.0)
      {
        printf("%.2f GiB\n", GB_SIZE)
      }
      else
      {
        MB_SIZE=(SIZE / 1024 / 1024)
        if (MB_SIZE > 1.0)
        {
          printf("%.2f MiB\n", MB_SIZE)
        }
        else
        {
          KB_SIZE=(SIZE / 1024)
          if (KB_SIZE > 1.0)
          {
            printf("%.2f KiB\n", KB_SIZE)
          }
          else
          {
            printf("%u B\n", SIZE)
          }
        }
      }
    }
  }'
}


# $1 = disk device to get partitions from, if not specified all available partitions are listed (without /dev/ prefix)
# Note that size is represented in 1KiB blocks
get_partitions_with_size()
{
  local DISK_NODEV=`echo "$1" |sed s,'^/dev/',,`
  local FIND_PARTS="$(cat /proc/partitions |sed -r -e '1,2d' -e s,'[[blank:]]+/dev/, ,' |awk '{ print $4" "$3 }')"

  if [ -n "$DISK_NODEV" ]; then
    echo "$FIND_PARTS" |grep -E "^${DISK_NODEV}p?[0-9]+"
  else
    echo "$FIND_PARTS" # Show all
  fi
}


# Safe (fixed) version of sgdisk since it doesn't always return non-zero when an error occurs
sgdisk_safe()
{
  local result=""
  local IFS=' '
  result="$(sgdisk $@ 2>&1)"
  local retval=$?

  if [ $retval -ne 0 ]; then
    echo "$result" >&2
    return $retval
  fi

  if ! echo "$result" |grep -i -q "operation has completed successfully"; then
    echo "$result" >&2
    return 8 # Seems to be the most appropriate return code for this
  fi

  echo "$result"
  return 0
}


# $1 = disk device to get partitions from, if not specified all available partitions are listed
get_partitions()
{
  get_partitions_with_size "$1" |awk '{ print $1 }'
}


# $1 = disk device to get partitions from, if not specified all available partitions are listed
get_partitions_with_size_type()
{
  local DISK_NODEV=`echo "$1" |sed s,'^/dev/',,`

  IFS=$EOL
  get_partitions "$DISK_NODEV" |while read LINE; do
    local PART_NODEV=`echo "$LINE" |awk '{ print $1 }'`

    local SIZE="$(blockdev --getsize64 "/dev/$PART_NODEV" 2>/dev/null)"
    if [ -z "$SIZE" ]; then
      SIZE=0
    fi
    local SIZE_HUMAN="$(human_size $SIZE |tr ' ' '_')"

    local BLKID_INFO="$(blkid -o full -s LABEL -s PTTYPE -s TYPE -s UUID -s PARTUUID "/dev/$PART_NODEV" 2>/dev/null |sed -e s,'^/dev/.*: ',, -e s,' *$',,)"
    if [ -z "$BLKID_INFO" ]; then
      BLKID_INFO="TYPE=\"unknown\""
    fi
    echo "$PART_NODEV: $BLKID_INFO SIZE=$SIZE SIZEH=$SIZE_HUMAN"
  done
}


# Figure out to which disk the specified partition ($1) belongs
get_partition_disk()
{
  local PARSE="$(echo "$1" |sed -r s,'[p/]?[0-9]+$',,)"

  # Make sure we don't just return the partition
  if [ "$PARSE" != "$1" ]; then
    echo "$PARSE"
  fi
}


# Get partitions directly from disk using sfdisk/gdisk
get_disk_partitions()
{
  local DISK_NODEV=`echo "$1" |sed s,'^/dev/',,`

  local SFDISK_OUTPUT="$(sfdisk -d "/dev/$DISK_NODEV" 2>/dev/null |grep '^/dev/')"
  if echo "$SFDISK_OUTPUT" |grep -q -E -i '^/dev/.*[[:blank:]]Id=ee' && check_command sgdisk; then
    local DEV_PREFIX="/dev/$DISK_NODEV"
    # FIXME: Not sure if this is correct:
    if echo "$DEV_PREFIX" |grep -q '[0-9]$'; then
      DEV_PREFIX="${DEV_PREFIX}p"
    fi

    sgdisk -p "/dev/$DISK_NODEV" 2>/dev/null |grep -E "^[[:blank:]]+[0-9]+" |awk '{ print DISK$1 }' DISK=$DEV_PREFIX
  else
    echo "$SFDISK_OUTPUT" |grep -E -v -i '[[:blank:]]Id= 0' |awk '{ print $1 }'
  fi
}


show_block_device_info()
{
  local BLK_NODEV=`echo "$1" |sed -e s,'^/dev/',, -e s,'^/sys/class/block/',,`
  local SYS_BLK="/sys/class/block/${BLK_NODEV}"

  local NAME=""

  local VENDOR="$(cat "${SYS_BLK}/device/vendor" 2>/dev/null |sed s!' *$'!!g)"
  if [ -n "$VENDOR" ]; then
    NAME="$VENDOR "
  fi

  local MODEL="$(cat "${SYS_BLK}/device/model"  2>/dev/null |sed s!' *$'!!g)"
  if [ -n "$MODEL" ]; then
    NAME="${NAME}${MODEL} "
  fi

  local REV="$(cat "${SYS_BLK}/device/rev"  2>/dev/null |sed s!' *$'!!g)"
  if [ -n "$REV" -a "$REV" != "n/a" ]; then
    NAME="${NAME}${REV} "
  fi

  if [ -n "$NAME" ]; then
    printf "$NAME"
  else
    printf "No info "
  fi

  local SIZE="$(blockdev --getsize64 "/dev/$BLK_NODEV" 2>/dev/null)"
  if [ -n "$SIZE" ]; then
    printf -- "- $SIZE bytes ($(human_size $SIZE))"
  fi

  echo ""
}


# Show block device partitions, automatically showing either DOS or GPT partition table
list_device_partitions()
{
  local DEVICE="$1"

  FDISK_OUTPUT="$(fdisk -l "$DEVICE" 2>/dev/null |grep -i -E -e '^/dev/' -e 'Device[[:blank:]]+Boot')"
  if echo "$FDISK_OUTPUT" |grep -q -E -i '^/dev/.*[[:blank:]]ee[[:blank:]]' && check_command gdisk; then
    # GPT partition table found
    GDISK_OUTPUT="$(gdisk -l "$DEVICE" 2>/dev/null |grep -i -E -e '^[[:blank:]]+[0-9]' -e '^Number')"
    printf "* GPT partition table:\n${GDISK_OUTPUT}\n\n"
  else
    # MBR/DOS Partitions:
    IFS=$EOL
    if echo "$FDISK_OUTPUT" |grep -E -i -v '^/dev/.*[[:blank:]]ee[[:blank:]]' |grep -q -E -i '^/dev/'; then
      printf "* DOS partition table:\n${FDISK_OUTPUT}\n\n"
    fi
  fi
}


# Get partition number from argument and return to stdout
get_partition_number()
{
  echo "$1" |sed -r -e s,'^[/a-z]*',, -e s,'^[0-9]+p',,
}


# Add partition number to device and return to stdout
# $1 = device
# $2 = number
add_partition_number()
{
  if [ -b "${1}${2}" ]; then
    echo "${1}${2}"
  elif [ -b "${1}p${2}" ]; then
    echo "${1}p${2}"
  else
    # Fallback logic:
    # FIXME: Not sure if this is correct:
    if echo "$1" |grep -q '[0-9]$'; then
      echo "${1}p${2}"
    else
      echo "${1}${2}"
    fi
  fi
}


# Get available devices/disks with /dev/ prefix
get_available_disks()
{
  local DEV_FOUND=""
  
  IFS=$EOL
  for BLK_DEVICE in /sys/block/*; do
    DEVICE="$(echo "$BLK_DEVICE" |sed s,'^/sys/block/','/dev/',)"
    if echo "$DEVICE" |grep -q -e '/loop[0-9]' -e '/sr[0-9]' -e '/fd[0-9]' -e '/ram[0-9]' || [ ! -b "$DEVICE" ]; then
      continue; # Ignore device
    fi

    local SIZE="$(blockdev --getsize64 "$DEVICE" 2>/dev/null)"
    if [ -z "$SIZE" -o "$SIZE" = "0" ]; then
      continue; # Ignore device
    fi

    DEV_FOUND="${DEV_FOUND}${DEVICE} "
  done

  echo "$DEV_FOUND"
}


show_available_disks()
{
  echo "* Available devices/disks:"

  IFS=' '
  for DISK_DEV in `get_available_disks`; do
    echo "  $DISK_DEV: $(show_block_device_info $DISK_DEV)"
  done

  echo ""
}


# Function checks (and waits) till the kernel ACTUALLY re-read the partition table
part_check()
{
  local DEVICE="$1"

  printf "Waiting for up to date partion table from kernel for $DEVICE..."

  # Retry several times since some daemons can block the re-reread for a while (like dm/lvm)
  IFS=' '
  local TRY=10
  while [ $TRY -gt 0 ]; do
    TRY=$(($TRY - 1))

    # First make sure all partitions reported by the disk exist according to the kernel in /dev/
    DISK_PARTITIONS="$(get_disk_partitions "$DEVICE" |sed -r -e s,'^[/a-z]*',, -e s,'^[0-9]+p',, |sort -n)"

    # Second make sure all partitions reported by the kernel in /dev/ exist according to the disk
    KERNEL_PARTITIONS="$(get_partitions "$DEVICE" |sed -r -e s,'^[/a-z]*',, -e s,'^[0-9]+p',, |sort -n)"

    # Compare the partition numbers
    if [ "$DISK_PARTITIONS" = "$KERNEL_PARTITIONS" ]; then
      echo ""
      return 0
    fi

    printf "."

    # Sleep 1 second:
    sleep 1
  done

  printf "\033[40m\033[1;31mFAILED!\n\033[0m" >&2
  return 1
}


# Wrapper for partprobe (call after performing a partition table update)
# $1 = Device to re-read
partprobe()
{
  local DEVICE="$1"
  local result=""

  echo "(Re)reading partition-table on $DEVICE..."

  # Retry several times since some daemons can block the re-reread for a while (like dm/lvm)
  local TRY=10
  while [ $TRY -gt 0 ]; do
    TRY=$(($TRY - 1))

    # Somehow using partprobe here doesn't always work properly, using sfdisk -R instead for now
    result="$(sfdisk -R "$DEVICE" 2>&1)"

    # Wait a sec for things to settle
    sleep 1

    if [ -z "$result" ]; then
      break;
    fi
  done

  if [ -n "$result" ]; then
    printf "\033[40m\033[1;31m${result}\n\033[0m" >&2
    return 1
  fi

  return 0
}


# Setup the ethernet interface
configure_network()
{
  IFS=$EOL
  for CUR_IF in $(ifconfig -s -a 2>/dev/null |grep -i -v '^iface' |awk '{ print $1 }' |grep -v -e '^dummy' -e '^bond' -e '^lo'); do
    IF_INFO="$(ifconfig $CUR_IF)"
    MAC_ADDR=`echo "$IF_INFO" |grep -i ' hwaddr ' |awk '{ print $NF }'`
    IP_TEST=""
    if [ -n "$MAC_ADDR" ]; then 
      # Old style ifconfig
      IP_TEST=`echo "$IF_INFO" |grep -i 'inet addr:.*Bcast.*Mask.*' |sed 's/^ *//g'`
    else
      # Check for new style ifconfig
      MAC_ADDR=`echo "$IF_INFO" |grep -i ' ether ' |awk '{ print $2 }'`
      if [ -z "$MAC_ADDR" ]; then
        echo "* Skipped auto config for interface: $CUR_IF"
        continue;
      fi
      IP_TEST=`echo "$IF_INFO" |grep -i 'inet .*netmask .*broadcast .*' |sed 's/^ *//g'`
    fi

    if [ -z "$IP_TEST" ] || ! ifconfig 2>/dev/null |grep -q -e "^${CUR_IF}[[:blank:]]" -e "^${CUR_IF}:"; then
      echo "* Network interface $CUR_IF is not active (yet)"

      if echo "$NETWORK" |grep -q -e 'dhcp'; then
        if check_command dhcpcd; then
          echo "* Trying DHCP IP (with dhcpcd) for interface $CUR_IF ($MAC_ADDR)..."
          # Run dhcpcd to get a dynamic IP
          if dhcpcd -L $CUR_IF; then
            continue
          fi
        elif check_command dhclient; then
          echo "* Trying DHCP IP (with dhclient) for interface $CUR_IF ($MAC_ADDR)..."
          if dhclient -1 $CUR_IF; then
            continue
          fi
        fi
      fi

      if echo "$NETWORK" |grep -q -e 'static'; then
        if ! get_user_yn "\n* Setup interface $CUR_IF statically (Y/N)?"; then
          continue;
        fi

        echo ""
        echo "* Static configuration for interface $CUR_IF ($MAC_ADDR)"
        printf "IP address ($IPADDRESS)?: "
        read USER_IPADDRESS
        if [ -z "$USER_IPADDRESS" ]; then
          USER_IPADDRESS="$IPADDRESS"
          if [ -z "$USER_IPADDRESS" ]; then
            echo "* Skipping configuration of $CUR_IF"
            continue
          fi
        fi

        printf "Netmask ($NETMASK)?: "
        read USER_NETMASK
        if [ -z "$USER_NETMASK" ]; then
          USER_NETMASK="$NETMASK"
        fi

        printf "Gateway ($GATEWAY)?: "
        read USER_GATEWAY
        if [ -z "$USER_GATEWAY" ]; then
          USER_GATEWAY="$GATEWAY"
        fi

        echo "* Configuring static IP: $USER_IPADDRESS / $USER_NETMASK"
        ifconfig $CUR_IF down
        ifconfig $CUR_IF inet $USER_IPADDRESS netmask $USER_NETMASK up
        if [ -n "$USER_GATEWAY" ]; then
          route add default gw $USER_GATEWAY
        fi
      fi
    else
      echo "* Using already configured IP for interface $CUR_IF ($MAC_ADDR): "
      echo "  $IP_TEST"
    fi
  done
}


# Check if DMA is enabled for HDD
check_dma()
{
  if check_command hdparm; then
    # DMA disabled?
    if hdparm -d "$1" 2>/dev/null |grep -q 'using_dma.*0'; then
      # Enable DMA
      hdparm -d1 "$1" >/dev/null
    fi
  else
    printf "\033[40m\033[1;31mWARNING: hdparm binary does not exist so not checking/enabling DMA!\033[0m\n" >&2
  fi
}


# Check whether a certain command is available
check_command()
{
  local path IFS

  IFS=' '
  for cmd in $*; do
    if [ -n "$(which "$cmd" 2>/dev/null)" ]; then
      return 0
    fi
  done
  
  return 1
}


# Check whether a binary is available and if not, generate an error and stop program execution
check_command_error()
{
  local IFS=' '

  if ! check_command "$@"; then
    printf "\033[40m\033[1;31mERROR  : Command(s) \"$(echo "$@" |tr ' ' '|')\" is/are not available!\033[0m\n" >&2
    printf "\033[40m\033[1;31m         Please investigate. Quitting...\033[0m\n" >&2
    echo ""
    exit 2
  fi
}


# Check whether a binary is available and if not, generate a warning but continue program execution
check_command_warning()
{
  local retval IFS=' '

  check_command "$@"
  retval=$?

  if [ $retval -ne 0 ]; then
    printf "\033[40m\033[1;31mWARNING: Command(s) \"$(echo "$@" |tr ' ' '|')\" is/are not available!\033[0m\n" >&2
    printf "\033[40m\033[1;31m         Please investigate. This *may* be a problem!\033[0m\n" >&2
    echo ""
  fi

  return $retval
}


sanity_check()
{
  # root check
  if [ "$(id -u)" != "0" ]; then
    printf "\033[40m\033[1;31mERROR: Root check FAILED (you MUST be root to use this script)! Quitting...\033[0m\n" >&2
    exit 1
  fi

  check_command_error awk
  check_command_error find
  check_command_error sed
  check_command_error grep
  check_command_error mkswap
  check_command_error sfdisk
  check_command_error fdisk
  check_command_error dd
  check_command_error blkid
  check_command_error lsblk
  check_command_error blockdev

  [ "$NO_NET" != "0" ] && check_command_error ifconfig
  [ "$NO_MOUNT" != "0" ] && check_command_error mount
  [ "$NO_MOUNT" != "0" ] && check_command_error umount

  # Sanity check devices and check if target devices exist
  IFS=' '
  for ITEM in $DEVICES; do
    SOURCE_DEVICE_NODEV=""

    TARGET_DEVICE_MAP=`echo "$ITEM" |cut -f2 -d"$SEP" -s`
    if [ -z "$TARGET_DEVICE_MAP" ]; then
      TARGET_DEVICE_MAP="$ITEM"
    else
      SOURCE_DEVICE_NODEV=`echo "$ITEM" |cut -f1 -d"$SEP"`
    fi

    if [ -n "$TARGET_DEVICE_MAP" ]; then
      if ! echo "$TARGET_DEVICE_MAP" |grep -q '^/dev/'; then
        echo ""
        printf "\033[40m\033[1;31mERROR: Specified target device $TARGET_DEVICE_MAP should start with /dev/! Quitting...\n\033[0m" >&2
        echo ""
        exit 5
      fi

      CHECK_DEVICE_NODEV=`echo "$TARGET_DEVICE_MAP" |sed s,'^/dev/',,`
    else
      if echo "$SOURCE_DEVICE_NODEV" |grep -q '^/dev/'; then
        echo ""
        printf "\033[40m\033[1;31mERROR: Specified (source) device $SOURCE_DEVICE_NODEV should exclude /dev/! Quitting...\n\033[0m" >&2
        echo ""
        exit 5
      fi

      CHECK_DEVICE_NODEV="$SOURCE_DEVICE_NODEV"
    fi

    if [ ! -e "/dev/$CHECK_DEVICE_NODEV" ]; then
      echo ""
      printf "\033[40m\033[1;31mERROR: Specified (target) block device /dev/$CHECK_DEVICE_NODEV does NOT exist! Quitting...\n\033[0m" >&2
      echo ""
      exit 5
    fi
  done

  # Sanity check partitions
  IFS=' '
  for ITEM in $PARTITIONS; do
    SOURCE_PARTITION_NODEV=`echo "$ITEM" |cut -f1 -d"$SEP"`
    TARGET_PARTITION_MAP=`echo "$ITEM" |cut -f2 -d"$SEP" -s`
    
    if [ -n "$TARGET_PARTITION_MAP" ]; then
      if ! echo "$TARGET_PARTITION_MAP" |grep -q '^/dev/'; then
        echo ""
        printf "\033[40m\033[1;31mERROR: Specified target partition $TARGET_PARTITION_MAP should start with /dev/! Quitting...\n\033[0m" >&2
        echo ""
        exit 5
      fi
    else
      if echo "$SOURCE_PARTITION_NODEV" |grep -q '^/dev/'; then
        echo ""
        printf "\033[40m\033[1;31mERROR: Specified (source) partition $SOURCE_PARTITION_NODEV should exclude /dev/! Quitting...\n\033[0m" >&2
        echo ""
        exit 5
      fi
    fi
  done
}


chdir_safe()
{
  local IMAGE_DIR="$1"

  if [ ! -d "$IMAGE_DIR" ]; then
    printf "\033[40m\033[1;31m\nERROR: Image source directory ($IMAGE_DIR) does NOT exist!\n\n\033[0m" >&2
    return 2
  fi

  # Make the image dir our working directory
  if ! cd "$IMAGE_DIR"; then
    printf "\033[40m\033[1;31m\nERROR: Unable to cd to image directory $IMAGE_DIR!\n\033[0m" >&2
    return 3
  fi
  
  return 0
}


set_image_source_dir()
{
  if echo "$IMAGE_NAME" |grep -q '^[\./]' || [ $NO_MOUNT -eq 1 ]; then
    # Assume absolute path
    IMAGE_DIR="$IMAGE_NAME"
    
    if ! chdir_safe "$IMAGE_DIR"; then
      do_exit 7
    fi

    # Reset mount device since we've been overruled
    MOUNT_DEVICE=""
  else
    if [ -n "$MOUNT_DEVICE" -a -n "$IMAGE_ROOT" ]; then
      # Create mount point
      if ! mkdir -p "$IMAGE_ROOT"; then
        echo ""
        printf "\033[40m\033[1;31mERROR: Unable to create directory for mount point $IMAGE_ROOT! Quitting...\n\033[0m" >&2
        echo ""
        exit 7
      fi

      # Unmount mount point to be used
      umount "$IMAGE_ROOT" 2>/dev/null
      echo ""

      if [ -n "$SERVER" -a -n "$DEFAULT_USERNAME" ]; then
        while true; do
          printf "Network username ($DEFAULT_USERNAME): "
          read USERNAME
          if [ -z "$USERNAME" ]; then
            USERNAME="$DEFAULT_USERNAME"
          fi

          echo "* Using network username $USERNAME"
          
          # Replace username in our mount arguments (it's a little dirty, I know ;-))
          MOUNT_ARGS="-t $MOUNT_TYPE -o $(echo "$MOUNT_OPTIONS" |sed "s/$DEFAULT_USERNAME$/$USERNAME/")"

          echo "* Mounting $MOUNT_DEVICE on $IMAGE_ROOT with arguments \"$MOUNT_ARGS\""
          IFS=' '
          if ! mount $MOUNT_ARGS "$MOUNT_DEVICE" "$IMAGE_ROOT"; then
            echo ""
            printf "\033[40m\033[1;31mERROR: Error mounting $MOUNT_DEVICE on $IMAGE_ROOT!\n\033[0m" >&2
            echo ""
          else
            break; # All done: break
          fi
        done
      else
        MOUNT_ARGS="-t $MOUNT_TYPE"

        echo "* Mounting $MOUNT_DEVICE on $IMAGE_ROOT with arguments \"$MOUNT_ARGS\""
        IFS=' '
        if ! mount $MOUNT_ARGS "$MOUNT_DEVICE" "$IMAGE_ROOT"; then
          echo ""
          printf "\033[40m\033[1;31mERROR: Error mounting $MOUNT_DEVICE on $IMAGE_ROOT! Quitting...\n\033[0m" >&2
          echo ""
          exit 6
        fi
      fi
    else
      # Reset mount device since we didn't mount
      MOUNT_DEVICE=""
    fi

    # The IMAGE_NAME was set from the commandline:
    if [ -n "$IMAGE_NAME" ]; then
      if [ -n "$IMAGE_ROOT" ]; then
        IMAGE_DIR="$IMAGE_ROOT/$IMAGE_NAME"
      else
        IMAGE_DIR="$IMAGE_NAME"
      fi
      
      if ! chdir_safe "$IMAGE_DIR"; then
        do_exit 7
      fi
    else
      IMAGE_DIR="$IMAGE_ROOT"
      if [ -z "$IMAGE_DIR" ]; then
        # Default to the cwd
        IMAGE_DIR=`pwd`
      fi

      if [ -z "$IMAGE_RESTORE_DEFAULT" ]; then
        IMAGE_RESTORE_DEFAULT="."
      fi

      # Ask user for IMAGE_NAME
      IMAGE_DEFAULT="$IMAGE_RESTORE_DEFAULT"
      while true; do
        echo "* Showing contents of the image root directory ($IMAGE_DIR):"
        IFS=$EOL
        find "$IMAGE_DIR" -mindepth 1 -maxdepth 1 -type d |sort |while read ITEM; do
          printf "$(stat -c "%y" "$ITEM" |sed s/'\..*'//)\t$(basename $ITEM)\n"
        done

        printf "\nImage (directory) to use ($IMAGE_DEFAULT): "
        read IMAGE_NAME

        if echo "$IMAGE_NAME" |grep -q "/$"; then
          if [ "$IMAGE_NAME" = "../" ]; then
            IMAGE_DIR="$(dirname "$IMAGE_DIR")" # Get rid of top directory
          else
            NEW_IMAGE_DIR="$IMAGE_DIR/$(echo "$IMAGE_NAME" |sed -e s:'^\./*':: -e s:'/*$'::)"
            if [ ! -d "$NEW_IMAGE_DIR" ]; then
              printf "\033[40m\033[1;31mERROR: Unable to access directory $NEW_IMAGE_DIR!\n\033[0m" >&2
            else
              IMAGE_DIR="$NEW_IMAGE_DIR"
              IMAGE_DEFAULT="."
            fi
          fi
          continue;
        fi

        if [ -z "$IMAGE_NAME" ]; then
           IMAGE_NAME="$IMAGE_DEFAULT"
        fi

        if [ -z "$IMAGE_NAME" -o "$IMAGE_NAME" = "." ]; then
          TEMP_IMAGE_DIR="$IMAGE_DIR"
        else
          TEMP_IMAGE_DIR="$IMAGE_DIR/$IMAGE_NAME"
        fi

        LOOKUP="$(find "$TEMP_IMAGE_DIR/" -maxdepth 1 -type f -iname "*.img.gz.000" -o -iname "*.fsa" -o -iname "*.dd.gz" -o -iname "*.pc.gz" 2>/dev/null)"
        if [ -z "$LOOKUP" ]; then
          printf "\033[40m\033[1;31m\nERROR: No valid image (directory) specified ($TEMP_IMAGE_DIR)!\n\n\033[0m" >&2
          continue;
        fi

        # Try to cd to the image directory
        if ! chdir_safe "$TEMP_IMAGE_DIR"; then
          continue;
        fi
        
        IMAGE_DIR="$TEMP_IMAGE_DIR"
        break; # All done: break
      done
    fi
  fi
}


image_type_detect()
{
  local IMAGE_FILE="$1"

  if echo "$IMAGE_FILE" |grep -q "\.fsa$"; then
    echo "fsarchiver"
  elif echo "$IMAGE_FILE" |grep -q "\.img\.gz"; then
    echo "partimage"
  elif echo "$IMAGE_FILE" |grep -q "\.pc\.gz$"; then
    echo "partclone"
  elif echo "$IMAGE_FILE" |grep -q "\.dd\.gz$"; then
    echo "ddgz"
  else
    echo "unknown"
  fi
}


# $1 = source without /dev/
# stdout = target with /dev/
source_to_target_remap()
{
  local IMAGE_PARTITION_NODEV="$1"

  # Set default
  local TARGET_DEVICE="/dev/$IMAGE_PARTITION_NODEV"

  # We want another target device than specified in the image name?:
  IFS=' '
  for ITEM in $DEVICES; do
    SOURCE_DEVICE_NODEV=""
    TARGET_DEVICE_MAP=`echo "$ITEM" |cut -f2 -d"$SEP" -s`
    if [ -z "$TARGET_DEVICE_MAP" ]; then
      TARGET_DEVICE_MAP="$ITEM"
    else
      SOURCE_DEVICE_NODEV=`echo "$ITEM" |cut -f1 -d"$SEP"`
    fi

    TARGET_DEVICE_MAP_NODEV=`echo "$TARGET_DEVICE_MAP" |sed s,'^/dev/',,`
    NUM=`get_partition_number "$IMAGE_PARTITION_NODEV"`
    if [ -n "$NUM" ]; then
      # Argument is a partition
      if [ -z "$SOURCE_DEVICE_NODEV" ] || echo "$IMAGE_PARTITION_NODEV" |grep -E -x -q "${SOURCE_DEVICE_NODEV}p?[0-9]+"; then
        TARGET_DEVICE=`add_partition_number "/dev/${TARGET_DEVICE_MAP_NODEV}" "${NUM}"`
        break;
      fi
    else
      # Argument is a disk
      TARGET_DEVICE="/dev/${TARGET_DEVICE_MAP_NODEV}"
      break;
    fi
  done

  # We want another target partition than specified in the image name?:
  IFS=' '
  for ITEM in $PARTITIONS; do
    SOURCE_PARTITION_NODEV=`echo "$ITEM" |cut -f1 -d"$SEP"`
    TARGET_PARTITION_MAP=`echo "$ITEM" |cut -f2 -d"$SEP" -s`

    if [ "$SOURCE_PARTITION_NODEV" = "$IMAGE_PARTITION_NODEV" -a -n "$TARGET_PARTITION_MAP" ]; then
      TARGET_DEVICE="$TARGET_PARTITION_MAP"
      break;
    fi
  done

  echo "$TARGET_DEVICE"
}


# $1=image-source-device
# $2=target-device
update_source_to_target_device_remap()
{
  local IMAGE_SOURCE_NODEV="$1"
  local TARGET_DEVICE="$2"

  local DEVICES_TEMP=""
  IFS=' '
  for ITEM in $DEVICES; do
    SOURCE_DEVICE_NODEV=""
    TARGET_DEVICE_MAP=`echo "$ITEM" |cut -f2 -d"$SEP" -s`
    if [ -z "$TARGET_DEVICE_MAP" ]; then
      TARGET_DEVICE_MAP="$ITEM"
    else
      SOURCE_DEVICE_NODEV=`echo "$ITEM" |cut -f1 -d"$SEP"`
    fi

    # Remove entries for specified device
    if [ "$SOURCE_DEVICE_NODEV" != "$IMAGE_SOURCE_NODEV" ]; then
    FAILED="${FAILED}${FAILED:+ }${TARGET_PARTITION}"
    
    DEVICES_TEMP="${DEVICES_TEMP}${DEVICES_TEMP:+,}${ITEM}"
    fi
  done

  # Update global devices (remap) variable
  DEVICES="${DEVICES_TEMP}${DEVICES_TEMP:+,}${IMAGE_SOURCE_NODEV}:${TARGET_DEVICE}"
}


restore_partitions()
{
  # Restore the actual image(s):
  IFS=' '
  for ITEM in $IMAGE_FILES; do
    IMAGE_FILE=`echo "$ITEM" |cut -f1 -d"$SEP" -s`
    TARGET_PARTITION=`echo "$ITEM" |cut -f2 -d"$SEP" -s`

    echo "* Selected partition: $TARGET_PARTITION. Using image file: $IMAGE_FILE"
    local retval=1
    case $(image_type_detect "$IMAGE_FILE") in
      fsarchiver) fsarchiver -v restfs "$IMAGE_FILE" id=0,dest="$TARGET_PARTITION"
                  retval=$?
                  ;;
      partimage)  partimage -b restore "$TARGET_PARTITION" "$IMAGE_FILE"
                  retval=$?
                  ;;
      partclone)  { $GZIP -d -c "$IMAGE_FILE"; echo $? >/tmp/.gzip.exitcode; } |partclone.restore -s - -o "$TARGET_PARTITION"
                  retval=$?
                  if [ $retval -eq 0 ]; then
                    retval=`cat /tmp/.gzip.exitcode`
                  fi
                  ;;
      ddgz)       { $GZIP -d -c "$IMAGE_FILE"; echo $? >/tmp/.gzip.exitcode; } |dd of="$TARGET_PARTITION" bs=4096
                  retval=$?
                  if [ $retval -eq 0 ]; then
                    retval=`cat /tmp/.gzip.exitcode`
                  fi
                  ;;
    esac

    if [ $retval -ne 0 ]; then
      FAILED="${FAILED}${FAILED:+ }${TARGET_PARTITION}"
      printf "\033[40m\033[1;31mWARNING: Error($retval) occurred during image restore for $IMAGE_FILE on $TARGET_PARTITION.\nPress <enter> to continue or CTRL-C to abort...\n\033[0m" >&2
      read dummy
    else
      SUCCESS="${SUCCESS}${SUCCESS:+ }${TARGET_PARTITION}"
      echo "****** $IMAGE_FILE restored to $TARGET_PARTITION ******"
    fi
    echo ""
  done
}


user_target_dev_select()
{
  local DEFAULT_TARGET_NODEV="$1"
  printf "Select target device (default=/dev/$DEFAULT_TARGET_NODEV): "
  read USER_TARGET_NODEV

  if [ -z "$USER_TARGET_NODEV" ]; then
    USER_TARGET_NODEV="$DEFAULT_TARGET_NODEV"
  fi

  # Auto remove /dev/ :
  if echo "$USER_TARGET_NODEV" |grep -q '^/dev/'; then
    USER_TARGET_NODEV="$(echo "$USER_TARGET_NODEV" |sed s,'^/dev/',,)"
  fi
}


get_source_disks()
{
  local USED_DISKS=""

  # Only check disk files if no partitions specified and the rule "all" applies
  if [ -z "$PARTITIONS" -o $CLEAN -eq 1 ]; then
    IFS=$EOL
    for ITEM in `find . -maxdepth 1 -name "track0.*" -o -name "sgdisk.*" -o -name "sfdisk.*"`; do
      # Extract drive name from file
      IMAGE_SOURCE_NODEV="$(basename "$ITEM" |sed -e s,'.*\.',, -e s,'_','/',g)"

      # Skip duplicates
      if ! echo "$USED_DISKS" |grep -q -e "^${IMAGE_SOURCE_NODEV}$" -e " ${IMAGE_SOURCE_NODEV}$" -e "^${IMAGE_SOURCE_NODEV} " -e " ${IMAGE_SOURCE_NODEV} "; then
        USED_DISKS="${USED_DISKS}${IMAGE_SOURCE_NODEV} "
      fi
    done
  fi

  # Check image files:
  IFS=$EOL
  for ITEM in `find . -maxdepth 1 -type f -iname "*.img.gz.000" -o -iname "*.fsa" -o -iname "*.dd.gz" -o -iname "*.pc.gz"`; do
    # Extract drive name from file
    IMAGE_SOURCE_NODEV="$(get_partition_disk "$(basename "$ITEM" |sed -e s,'\..*',, -e s,'_','/',g)")"

    if [ -n "$PARTITIONS" ] && ! echo "$PARTITIONS" |grep -q -e "^${IMAGE_SOURCE_NODEV}$" -e " ${IMAGE_SOURCE_NODEV}$" -e "^${IMAGE_SOURCE_NODEV}[ :]" -e " ${IMAGE_SOURCE_NODEV}[ :]"; then
      continue; # Not specified in --partitions, skip
    fi

    # Skip duplicates
    if ! echo "$USED_DISKS" |grep -q -e "^${IMAGE_SOURCE_NODEV}$" -e " ${IMAGE_SOURCE_NODEV}$" -e "^${IMAGE_SOURCE_NODEV} " -e " ${IMAGE_SOURCE_NODEV} "; then
      USED_DISKS="${USED_DISKS}${IMAGE_SOURCE_NODEV} "
    fi
  done

  echo "$USED_DISKS"
}


# Returns best suitable target device, prefer unmounted disks (without /dev/ prefix)
get_auto_target_device()
{
  local SOURCE_NODEV="$1"
  local MIN_SIZE="$2"

  #FIXME: Check disk-size with MIN_SIZE?
  if [ -z "$MIN_SIZE" ]; then
    MIN_SIZE=0
  fi

  # Check for device existence and mounted partitions, prefer non-removable devices. Also check size of target
  if [ ! -b "/dev/$SOURCE_NODEV" ] || [ "$(cat /sys/block/$SOURCE_NODEV/removable 2>/dev/null)" = "1" ] || [ $(blockdev --getsize64 /dev/$SOURCE_NODEV) -lt $MIN_SIZE ] \
  || grep -E -q "^/dev/${SOURCE_NODEV}p?[0-9]+[[:blank:]]" /etc/mtab || grep -E -q "^/dev/${SOURCE_NODEV}p?[0-9]+[[:blank:]]" /proc/swaps; then
    IFS=' '
    for DISK_DEV in `get_available_disks`; do
      # Checked for mounted partitions
      if [ "$(cat /sys/block/$DISK_DEV/removable 2>/dev/null)" != "1" ] && ! grep -E -q "^${DISK_DEV}p?[0-9]+[[:blank:]]" /etc/mtab && ! grep -E -q "^${DISK_DEV}p?[0-9]+[[:blank:]]" /proc/swaps; then
        SOURCE_NODEV=`echo "$DISK_DEV" |sed s,'^/dev/',,`
        break;
      fi
      #FIXME: Skip check above when --clean is not specified?
    done
  fi

  echo "$SOURCE_NODEV"
}


check_disks()
{
  # Show disks/devices available for restoration
  show_available_disks;

  # Restore MBR/track0/partitions:
  IFS=' '
  for IMAGE_SOURCE_NODEV in `get_source_disks`; do
    IMAGE_TARGET_NODEV=`source_to_target_remap "$IMAGE_SOURCE_NODEV" |sed s,'^/dev/',,`

    if [ "$IMAGE_TARGET_NODEV" = "$IMAGE_SOURCE_NODEV" ]; then
      # Check whether device is available (eg. not mounted partitions and fallback to other default device if so)
      IMAGE_TARGET_NODEV=`get_auto_target_device "$IMAGE_SOURCE_NODEV"`
    fi

    if [ -z "$IMAGE_TARGET_NODEV" ]; then
      printf "\033[40m\033[1;31m\nERROR: No suitable device (disk) found for restore (too small?)! Quitting...\n\033[0m" >&2
      do_exit 5
    fi

    echo "* Auto preselecting target device /dev/$IMAGE_TARGET_NODEV for image source $IMAGE_SOURCE_NODEV"

    while true; do
      user_target_dev_select "$IMAGE_TARGET_NODEV"
      TARGET_NODEV="$USER_TARGET_NODEV"

      if [ -z "$TARGET_NODEV" ]; then
        continue;
      fi

      # Check if target device exists
      if [ ! -b "/dev/$TARGET_NODEV" ]; then
        echo ""
        printf "\033[40m\033[1;31mERROR: Target device /dev/$TARGET_NODEV does NOT exist!\n\n\033[0m" >&2
        continue;
      fi

      echo ""

      local DEVICE_TYPE="$(lsblk -d -n -o TYPE /dev/$TARGET_NODEV)"
      # Make sure it's a real disk
      if [ "$DEVICE_TYPE" = "disk" ]; then
        # Make sure kernel doesn't use old partition table
        if ! partprobe "/dev/$TARGET_NODEV" && [ $FORCE -ne 1 ]; then
          echo ""
          printf "\033[40m\033[1;31mERROR: Unable to obtain exclusive access on target device /dev/$TARGET_NODEV! Wrong target device specified and/or mounted partitions? Use --force to override.\n\n\033[0m" >&2
          continue;
        fi
        

        # Check if DMA is enabled for device
        check_dma "/dev/$TARGET_NODEV"
       fi

      echo ""

      if [ "$IMAGE_TARGET_NODEV" != "$TARGET_NODEV" ]; then
        update_source_to_target_device_remap "$IMAGE_SOURCE_NODEV" "/dev/$TARGET_NODEV"
      fi
      break;
    done

    # Check whether device already contains partitions
    PARTITIONS_FOUND="$(get_partitions "$TARGET_NODEV")"

    if [ -n "$PARTITIONS_FOUND" ]; then
      echo "* NOTE: Target device /dev/$TARGET_NODEV already contains partitions:"
      get_partitions_with_size_type /dev/$TARGET_NODEV
    fi

    if [ $PT_ADD -eq 1 ]; then
      if [ -e "gdisk.${IMAGE_SOURCE_NODEV}" ]; then
        # GPT:
        GDISK_TARGET="$(gdisk -l "/dev/${TARGET_NODEV}" |grep -E '^[[:blank:]]+[0-9]')"
        if [ -z "$GDISK_TARGET" ]; then
          printf "\033[40m\033[1;31m\nERROR: Unable to get GPT partitions from device /dev/${TARGET_NODEV} ! Quitting...\n\033[0m" >&2
          do_exit 5
        fi

        local MISMATCH=0
        IFS=$EOL
        for PART in $GDISK_TARGET; do
          # Check entry on source
          if ! grep -q -x "$PART" "gdisk.${IMAGE_SOURCE_NODEV}"; then
            MISMATCH=1
            break;
          fi
        done

        if [ $MISMATCH -eq 1 ]; then
          printf "\033[40m\033[1;31mERROR: Target GPT partition(s) mismatches with source. Unable to update GPT partition table (--add)! Quitting...\n\033[0m" >&2

          #TODO: Show source/target?
          echo "* Source GPT partition table (/dev/$IMAGE_SOURCE_NODEV):"
          grep -E '^[[:blank:]]+[0-9]' "gdisk.${IMAGE_SOURCE_NODEV}"
          echo ""

          echo "* Target GPT partition table (/dev/$TARGET_NODEV):"
          echo "$GDISK_TARGET"

          do_exit 5
        fi
      elif [ -e "sfdisk.${IMAGE_SOURCE_NODEV}" ]; then
        # DOS/MBR:
        SFDISK_TARGET="$(sfdisk -d "/dev/${TARGET_NODEV}" |grep -i '^/dev/.*Id=' |grep -i -v 'Id= 0$' |sed s,'^/dev/[a-z]+',, -e s,'^[0-9]+p',,)"
        if [ -z "$SFDISK_TARGET" ]; then
          printf "\033[40m\033[1;31m\nERROR: Unable to get DOS partitions from device /dev/${TARGET_NODEV} ! Quitting...\n\033[0m" >&2
          do_exit 5
        fi

        MISMATCH=0
        IFS=$EOL
        for PART in $SFDISK_TARGET; do
          if ! grep -q "[a-z]${PART}$" "sfdisk.${IMAGE_SOURCE_NODEV}"; then
            MISMATCH=1
            break;
          fi
        done

        if [ $MISMATCH -eq 1 ]; then
          printf "\033[40m\033[1;31mERROR: Target DOS partition(s) mismatches with source. Unable to update DOS partition table (--add)! Quitting...\n\033[0m" >&2
          
          echo "* Source DOS partition table (/dev/$IMAGE_SOURCE_NODEV):"
          cat "sfdisk.${IMAGE_SOURCE_NODEV}"
          echo ""
          
          echo "* Target DOS partition table (/dev/$TARGET_NODEV):"
          echo "$SFDISK_TARGET"

          do_exit 5
        fi
      fi
    fi

    local ENTER=0

    if [ $CLEAN -eq 0 -a -n "$PARTITIONS_FOUND" ]; then
      if [ $PT_WRITE -eq 0 -a $PT_ADD -eq 0 -a $MBR_WRITE -eq 0 ]; then
        echo "" >&2
        printf "\033[40m\033[1;31mWARNING: Since target device /dev/$TARGET_NODEV already has a partition-table (+possible bootloader), it will NOT be updated!\n\033[0m" >&2
        echo "To override this you must specify --clean or --pt --mbr..." >&2
        ENTER=1
      else
        if [ $PT_WRITE -eq 0 -a $PT_ADD -eq 0 ]; then
          echo "" >&2
          printf "\033[40m\033[1;31mWARNING: Since target device /dev/$TARGET_NODEV already has a partition-table, it will NOT be updated!\n\033[0m" >&2
          echo "To override this you must specify --clean or --pt..." >&2
          ENTER=1
        fi

        if [ $MBR_WRITE -eq 0 -a -e "track0.${IMAGE_SOURCE_NODEV}" ]; then
          echo "" >&2
          printf "\033[40m\033[1;31mWARNING: Since target device /dev/$TARGET_NODEV already has a partition-table, its MBR will NOT be updated!\n\033[0m" >&2
          echo "To override this you must specify --clean or --mbr..." >&2
          ENTER=1
        fi
      fi
    fi

    if [ $CLEAN -eq 1 -o $MBR_WRITE -eq 1 ] &&
       [ ! -e "track0.${IMAGE_SOURCE_NODEV}" -a -e "sfdisk.${IMAGE_SOURCE_NODEV}" ]; then
      printf "\033[40m\033[1;31mWARNING: track0.${IMAGE_SOURCE_NODEV} does NOT exist! Won't be able to update MBR boot loader\n\033[0m" >&2
      ENTER=1
    fi

    if [ $CLEAN -eq 1 -o $PT_WRITE -eq 1 -o $PT_ADD -eq 1 ] &&
       [ ! -e "sfdisk.${IMAGE_SOURCE_NODEV}" -a ! -e "sgdisk.${IMAGE_SOURCE_NODEV}" ]; then
      printf "\033[40m\033[1;31mWARNING: sgdisk/sfdisk.${IMAGE_SOURCE_NODEV} does NOT exist! Won't be able to update partition table!\n\033[0m" >&2
      ENTER=1
    fi

    if [ $ENTER -eq 1 ]; then
      echo "" >&2
      printf "Press <enter> to continue or CTRL-C to abort...\n" >&2
      read dummy
    fi

    DEVICE_FILES="${DEVICE_FILES}${DEVICE_FILES:+ }${IMAGE_SOURCE_NODEV}${SEP}${TARGET_NODEV}"
    TARGET_DEVICES="${TARGET_DEVICES}${TARGET_DEVICES:+ }/dev/${TARGET_NODEV}"

    if [ $CLEAN -eq 1 -o $PT_WRITE -eq 1 -o $MBR_WRITE -eq 1 ]; then
      IFS=$EOL
      for PART in $PARTITIONS_FOUND; do
        # Check for mounted partitions on target device
        if grep -E -q "^/dev/${PART}[[:blank:]]" /etc/mtab; then
          echo ""
          if [ $FORCE -eq 1 ]; then
            printf "\033[40m\033[1;31mWARNING: Partition /dev/$PART on target device is mounted!\n\033[0m" >&2
          else
            printf "\033[40m\033[1;31mERROR: Partition /dev/$PART on target device is mounted! Wrong target device specified (Use --force to override)? Quitting...\n\033[0m" >&2
            do_exit 5
          fi
        fi

        # Check for swap on target device
        if grep -E -q "^/dev/${PART}[[:blank:]]" /proc/swaps; then
          echo ""
          if [ $FORCE -eq 1 ]; then
            printf "\033[40m\033[1;31mWARNING: Partition /dev/$PART on target device is used as swap!\n\033[0m" >&2
          else
            printf "\033[40m\033[1;31mERROR: Partition /dev/$PART on target device is used as swap. Wrong target device specified (Use --force to override)? Quitting...\n\033[0m" >&2
            do_exit 5
          fi
        fi
      done
    fi
  done
}


restore_disks()
{
  local TRACK0_CLEAN
  local PARTPROBE

  # Restore MBR/track0/partitions
  unset IFS
  for ITEM in $DEVICE_FILES; do
    # Extract drive name from file
    IMAGE_SOURCE_NODEV=`echo "$ITEM" |cut -f1 -d"$SEP"`
    TARGET_NODEV=`echo "$ITEM" |cut -f2 -d"$SEP" -s`

    # Check whether device already contains partitions
    PARTITIONS_FOUND="$(get_partitions "$TARGET_NODEV")"

    # Flag in case we update the mbr/partition-table so we know we need to have the kernel to re-probe
    PARTPROBE=0

    # Clear all (GPT) partition data on --clean:
    if [ $CLEAN -eq 1 ] && check_command sgdisk; then
      # Clear GPT entries before zapping them else sgdisk --load-backup (below) may complain
      sgdisk --clear /dev/$TARGET_NODEV >/dev/null 2>&1

      # Completely zap GPT, MBR and legacy partition data, if we're using GPT on one of the devices
      sgdisk --zap-all /dev/$TARGET_NODEV >/dev/null 2>&1
    fi

    TRACK0_CLEAN=0
    if [ -z "$PARTITIONS_FOUND" -o $CLEAN -eq 1 ] && [ $NO_TRACK0 -eq 0 ]; then
      TRACK0_CLEAN=1
    fi

    DD_SOURCE="track0.${IMAGE_SOURCE_NODEV}"
    if [ -e "$DD_SOURCE" ]; then
      # Check for MBR restore:
      if [ $MBR_WRITE -eq 1 -o $TRACK0_CLEAN -eq 1 ]; then
        echo "* Updating track0(MBR) on /dev/$TARGET_NODEV from $DD_SOURCE:"

        if [ $CLEAN -eq 1 -o -z "$PARTITIONS_FOUND" ]; then
#          dd if="$DD_SOURCE" of=/dev/$TARGET_NODEV bs=512 count=63
          # For clean or empty disks always try to use a full 1MiB of DD_SOURCE else Grub2 may not work.
          dd if="$DD_SOURCE" of=/dev/$TARGET_NODEV bs=512 count=2048
          retval=$?
        else
          # FIXME: Need to detect the empty space before the first partition since GRUB2 may be longer than 32256 bytes!
          dd if="$DD_SOURCE" of=/dev/$TARGET_NODEV bs=446 count=1 && dd if="$DD_SOURCE" of=/dev/$TARGET_NODEV bs=512 seek=1 skip=1 count=62
          retval=$?
        fi

        if [ $retval -ne 0 ]; then
          printf "\033[40m\033[1;31mERROR: Track0(MBR) update from $DD_SOURCE to /dev/$TARGET_NODEV failed($retval). Quitting...\n\033[0m" >&2
          do_exit 5
        fi
        PARTPROBE=1
      fi
    fi

    # Check for partition restore
    if [ $TRACK0_CLEAN -eq 1 -o $PT_WRITE -eq 1 -o $PT_ADD -eq 1 ]; then
      SGDISK_FILE="sgdisk.${IMAGE_SOURCE_NODEV}"
      if [ -e "$SGDISK_FILE" ]; then
        echo "* Updating GPT partition-table on /dev/$TARGET_NODEV:"
        result="$(sgdisk_safe --load-backup="$SGDISK_FILE" /dev/$TARGET_NODEV 2>&1)"
        retval=$?

        if [ $retval -ne 0 ]; then
          echo "$result" >&2
          printf "\033[40m\033[1;31mGPT partition-table restore failed($retval). Quitting...\n\033[0m" >&2
          do_exit 5
        else
          echo "$result"
        fi
        PARTPROBE=1
      else
        SFDISK_FILE=""
        if [ -e "sfdisk.${IMAGE_SOURCE_NODEV}" ]; then
          SFDISK_FILE="sfdisk.${IMAGE_SOURCE_NODEV}"
        elif [ -e "partitions.${IMAGE_SOURCE_NODEV}" ] && grep -q '^# partition table of' "partitions.${IMAGE_SOURCE_NODEV}"; then
          # Legacy fallback
          SFDISK_FILE="partitions.${IMAGE_SOURCE_NODEV}"
        fi

        if [ -n "$SFDISK_FILE" ]; then
          echo "* Updating DOS partition-table on /dev/$TARGET_NODEV:"
          result="$(sfdisk --force --no-reread /dev/$TARGET_NODEV < "$SFDISK_FILE" 2>&1)"
          retval=$?

          # Can't just check sfdisk's return code as it is not reliable
          if ! echo "$result" |grep -i -q "^Successfully wrote" || echo "$result" |grep -i -q -e "^Warning.*extends past end of disk" -e "^Warning.*exceeds max"; then
            echo "$result" >&2
            printf "\033[40m\033[1;31mDOS partition-table restore failed($retval). Quitting...\n\033[0m" >&2
            do_exit 5
          else
            echo "$result" |grep -i -e 'Success'
          fi
          PARTPROBE=1
        fi
      fi
      list_device_partitions /dev/$TARGET_NODEV
    fi

    if [ $PARTPROBE -eq 1 ]; then
      # Wait for kernel to reread partition table
      if partprobe "/dev/$TARGET_NODEV" && part_check "/dev/$TARGET_NODEV"; then
        echo ""
      elif [ $FORCE -ne 1 ]; then
        printf "\033[40m\033[1;31mWARNING: (Re)reading the partition-table failed! Use --force to override.\n\033[0m" >&2
        do_exit 5;
      fi
    fi
  done
}


check_image_files()
{
  IMAGE_FILES=""
  if [ -n "$PARTITIONS" ]; then
    IFS=','
    for ITEM in $PARTITIONS; do
      PART_NODEV=`echo "$ITEM" |cut -f1 -d"$SEP"`

      IFS=$EOL
      LOOKUP="$(find . -maxdepth 1 -type f -iname "${PART_NODEV}.img.gz.000" -o -iname "${PART_NODEV}.fsa" -o -iname "${PART_NODEV}.dd.gz" -o -iname "${PART_NODEV}.pc.gz")"

      if [ -z "$LOOKUP" ]; then
        printf "\033[40m\033[1;31m\nERROR: Image file for partition $PART_NODEV could not be located! Quitting...\n\033[0m" >&2
        do_exit 5
      fi

      if [ $(echo "$LOOKUP" |wc -l) -gt 1 ]; then
        echo "$LOOKUP"
        printf "\033[40m\033[1;31m\nERROR: Found multiple image files for partition $PART_NODEV! Quitting...\n\033[0m" >&2
        do_exit 5
      fi

      IMAGE_FILE=`basename "$LOOKUP"`

      # Construct device name:
      SOURCE_NODEV="$(echo "$IMAGE_FILE" |sed -e s,'\..*',, -e s,'_','/',g)"
      TARGET_PARTITION=`source_to_target_remap "$SOURCE_NODEV"`

      # Add item to list
      IMAGE_FILES="${IMAGE_FILES}${IMAGE_FILES:+ }${IMAGE_FILE}${SEP}${TARGET_PARTITION}"
    done
  else
    IFS=$EOL
    for ITEM in $(find . -maxdepth 1 -type f -iname "*.img.gz.000" -o -iname "*.fsa" -o -iname "*.dd.gz" -o -iname "*.pc.gz" |sort); do
      # FIXME: Can have multiple images here!
      IMAGE_FILE=`basename "$ITEM"`

      # Construct device name:
      SOURCE_NODEV="$(echo "$IMAGE_FILE" |sed -e s,'\..*',, -e s,'_','/',g)"
      TARGET_PARTITION=`source_to_target_remap "$SOURCE_NODEV"`

      if echo "$IMAGE_FILES" |grep -q -e "${SEP}${TARGET_PARTITION}$" -e "${SEP}${TARGET_PARTITION} "; then
        printf "\033[40m\033[1;31m\nERROR: Found multiple image files for partition $TARGET_PARTITION! Quitting...\n\033[0m" >&2
        do_exit 5
      fi

      # Add item to list
      IMAGE_FILES="${IMAGE_FILES}${IMAGE_FILES:+ }${IMAGE_FILE}${SEP}${TARGET_PARTITION}"
    done
  fi

  if [ -z "$IMAGE_FILES" ]; then
    printf "\033[40m\033[1;31m\nERROR: No (matching) image files found to restore! Quitting...\n\033[0m" >&2
    do_exit 5
  fi

  # Make sure the proper binaries are available
  IFS=' '
  for ITEM in $IMAGE_FILES; do
    IMAGE_FILE=`echo "$ITEM" |cut -f1 -d"$SEP"`
    
    case $(image_type_detect "$IMAGE_FILE") in
      fsarchiver) check_command_error fsarchiver
                  ;;
      partimage ) check_command_error partimage
                  ;;
      partclone ) check_command_error partclone.restore
                  check_command_error gzip
                  GZIP="gzip"
                  ;;
      ddgz      ) check_command_error gzip
                  GZIP="gzip"
                  ;;
    esac
  done
}


check_partitions()
{
  IFS=' '
  for ITEM in $IMAGE_FILES; do
    IMAGE_FILE=`echo "$ITEM" |cut -f1 -d"$SEP" -s`
    TARGET_PARTITION=`echo "$ITEM" |cut -f2 -d"$SEP" -s`

    echo "* Using image file \"${IMAGE_FILE}\" for partition $TARGET_PARTITION"

    # Check whether we need to add this to our included devices list
    PART_DISK="$(get_partition_disk "$TARGET_PARTITION")"
    if [ -z "$PART_DISK" ]; then
      echo "* NOTE: No parent disk found for target partition $TARGET_PARTITION" >&2
    elif ! echo "$TARGET_DEVICES" |grep -q -e "^$PART_DISK " -e " $PART_DISK " -e " $PART_DISK$" -e "^$PART_DISK$"; then
      TARGET_DEVICES="${TARGET_DEVICES}${TARGET_DEVICES:+ }${PART_DISK} "
    fi

    # Check for mounted partitions on target device
    if grep -E -q "^${TARGET_PARTITION}[[:blank:]]" /etc/mtab; then
      printf "\033[40m\033[1;31m\nERROR: Target partition $TARGET_PARTITION is mounted! Wrong target partition/device specified? Quitting...\n\033[0m" >&2
      do_exit 5
    fi

    # Check for swaps on this device
    if grep -E -q "^${TARGET_PARTITION}[[:blank:]]" /proc/swaps; then
      printf "\033[40m\033[1;31m\nERROR: Target partition $TARGET_PARTITION is used as swap. Wrong target partition/device specified? Quitting...\n\033[0m" >&2
      do_exit 5
    fi
  done

  return 0
}


show_target_devices()
{
  IFS=' '
  for DEVICE in $TARGET_DEVICES; do
    echo "* Using (target) device $DEVICE: $(show_block_device_info $DEVICE)"
  done
}


compare_dos_partition()
{
  local SOURCE_PART="$(echo "$1" |sed -r -e 's!^/dev/[a-z]+!!' -e 's!^[0-9]+p!!' -e 's!start= *[0-9]+, *!!' -e 's!size= *!!' |tr 'A-Z' 'a-z')"
  local TARGET_PART="$(echo "$2" |sed -r -e 's!^/dev/[a-z]+!!' -e 's!^[0-9]+p!!' -e 's!start= *[0-9]+, *!!' -e 's!size= *!!' |tr 'A-Z' 'a-z')"

  local retval=0

  local SOURCE_NUM="$(echo "$SOURCE_PART" |awk '{ print $1 }')"
  local TARGET_NUM="$(echo "$TARGET_PART" |awk '{ print $1 }')"

  # Check type / flags
  local SOURCE_TYPE="$(echo "$SOURCE_PART" |sed -r 's![0-9: ,]+!!')"
  local TARGET_TYPE="$(echo "$TARGET_PART" |sed -r 's![0-9: ,]+!!')"
  if [ "$SOURCE_TYPE" != "$TARGET_TYPE" ]; then
    printf "\033[40m\033[1;31mWARNING: Target partition $TARGET_NUM has different type/flags than source partition $SOURCE_NUM!\n\033[0m" >&2
    retval=1
  fi

  local SOURCE_SIZE="$(echo "$SOURCE_PART" |sed -r -e 's![0-9]+[ :]+!!' -e 's!,.*!!')"
  local TARGET_SIZE="$(echo "$TARGET_PART" |sed -r -e 's![0-9]+[ :]+!!' -e 's!,.*!!')"

  # Target is smaller?
  if [ $SOURCE_SIZE -gt $TARGET_SIZE ]; then
    printf "\033[40m\033[1;31mERROR: Target partition $TARGET_NUM is smaller than source partition $SOURCE_NUM!\n\033[0m" >&2
    retval=1
  fi

  # Target is bigger?
  if [ $SOURCE_SIZE -lt $TARGET_SIZE ]; then
    echo "NOTE: Target partition $TARGET_NUM is bigger than source partition $SOURCE_NUM"
  fi

  return $retval
}


compare_gpt_partition()
{
  local SOURCE_PART="$1"
  local TARGET_PART="$2"

  local retval=0

  local SOURCE_NUM="$(echo "$SOURCE_PART" |awk '{ print $1 }')"
  local TARGET_NUM="$(echo "$TARGET_PART" |awk '{ print $1 }')"

  # Check type / flags
  local SOURCE_TYPE="$(echo "$SOURCE_PART" |awk '{ print substr($0, index($0,$6)) }')"
  local TARGET_TYPE="$(echo "$TARGET_PART" |awk '{ print substr($0, index($0,$6)) }')"
  if [ "$SOURCE_TYPE" != "$TARGET_TYPE" ]; then
    printf "\033[40m\033[1;31mWARNING: Target partition $TARGET_NUM has different type/flags than source partition $SOURCE_NUM!\n\033[0m" >&2
    retval=1
  fi

  local SOURCE_SIZE="$(echo "$SOURCE_PART" |awk '{ print $3 - $2 }')"
  local TARGET_SIZE="$(echo "$TARGET_PART" |awk '{ print $3 - $2 }')"

  # Target is smaller?
  if [ $SOURCE_SIZE -gt $TARGET_SIZE ]; then
    printf "\033[40m\033[1;31mERROR: Target partition $TARGET_NUM is smaller than source partition $SOURCE_NUM!\n\033[0m" >&2
    retval=1
  fi

  # Target is bigger?
  if [ $SOURCE_SIZE -lt $TARGET_SIZE ]; then
    echo "NOTE: Target partition $TARGET_NUM is bigger than source partition $SOURCE_NUM"
  fi

  return $retval
}


test_target_partitions()
{
  if [ -z "$IMAGE_FILES" ]; then
    return 1 # Nothing to do
  fi

  echo ""

  # Test whether the target partition(s) exist and have the correct geometry:
  local MISMATCH=0
  IFS=' '
  for ITEM in $IMAGE_FILES; do
    IMAGE_FILE=$(echo "$ITEM" |cut -f1 -d"$SEP" -s)
    TARGET_PARTITION=$(echo "$ITEM" |cut -f2 -d"$SEP" -s)

    # Strip extension so we get the actual device name
    IMAGE_PARTITION_NODEV=$(echo "$IMAGE_FILE" |sed 's/\..*//')
    SOURCE_DISK_NODEV=$(get_partition_disk "$IMAGE_PARTITION_NODEV")
    TARGET_DISK=$(get_partition_disk "$TARGET_PARTITION")

    # FIXME: What to do if one translates to a disk?
    if [ -z "$SOURCE_DISK_NODEV" -o -z "$TARGET_DISK" ]; then
      continue; # No partitions on this device
    fi

    if [ -e "gdisk.${SOURCE_DISK_NODEV}" ]; then
      GDISK_TARGET_PART="$(gdisk -l "$TARGET_DISK" |grep -E "^[[:blank:]]+$(get_partition_number "$TARGET_PARTITION")[[:blank:]]")"
      if [ -n "$GDISK_TARGET_PART" ]; then
        GDISK_SOURCE_PART="$(grep -E "^[[:blank:]]+$(get_partition_number "$IMAGE_PARTITION_NODEV")[[:blank:]]" "gdisk.${SOURCE_DISK_NODEV}" 2>/dev/null)"

        echo "* Source GPT partition: $GDISK_SOURCE_PART"
        echo "* Target GPT partition: $GDISK_TARGET_PART"

        # Match partition with what we have stored in our partitions file
        if [ -z "$GDISK_SOURCE_PART" ]; then
          printf "\033[40m\033[1;31m\nWARNING: GPT partition /dev/$IMAGE_PARTITION_NODEV can not be found in partition source files!\n\033[0m" >&2
          echo ""
          MISMATCH=1
          continue;
        fi

        if ! compare_gpt_partition "$GDISK_SOURCE_PART" "$GDISK_TARGET_PART"; then
          MISMATCH=1
        fi
      else
        printf "\033[40m\033[1;31m\nERROR: Unable to detect target partition $TARGET_PARTITION! Quitting...\n\033[0m" >&2
        do_exit 5
      fi
    else
      SFDISK_TARGET_PART="$(sfdisk -d "$TARGET_DISK" 2>/dev/null |grep -E "^${TARGET_PARTITION}[[:blank:]]")"
      if [ -n "$SFDISK_TARGET_PART" ]; then
        # DOS partition found
        SFDISK_SOURCE_PART="$(grep -E "^/dev/${IMAGE_PARTITION_NODEV}[[:blank:]]" "sfdisk.${SOURCE_DISK_NODEV}" 2>/dev/null)"
        # If empty, try old (legacy) file
        if [ -z "$SFDISK_SOURCE_PART" -a -e "partitions.${SOURCE_DISK_NODEV}" ] && grep -q '^# partition table of' "partitions.${SOURCE_DISK_NODEV}"; then
          SFDISK_SOURCE_PART="$(grep -E "^/dev/${IMAGE_PARTITION_NODEV}[[:blank:]]" "partitions.${SOURCE_DISK_NODEV}" 2>/dev/null)"
        fi

        echo "* Source DOS partition: $SFDISK_SOURCE_PART"
        echo "* Target DOS partition: $SFDISK_TARGET_PART"

        # Match partition with what we have stored in our partitions file
        if [ -z "$SFDISK_SOURCE_PART" ]; then
          printf "\033[40m\033[1;31m\nWARNING: DOS partition /dev/$IMAGE_PARTITION_NODEV can not be found in the partition source files!\n\033[0m" >&2
          echo ""
          MISMATCH=1
          continue;
        fi

        # Check geometry/type of partition
        if ! compare_dos_partition "$SFDISK_SOURCE_PART" "$SFDISK_TARGET_PART"; then
          MISMATCH=1
        fi
      fi
    fi
  done

  echo ""

  if [ $MISMATCH -ne 0 ]; then
    printf "\033[40m\033[1;31mWARNING: Target partition mismatches with source!\n\033[0m" >&2
    if ! get_user_yn "Continue anyway (Y/N)?"; then
      echo "Aborted by user..."
      do_exit 5;
    fi
    return 1
  fi

  return 0
}


# Create swap partitions on all target devices
create_swaps()
{
  local SWAP_COUNT=0

  IFS=' '
  for DEVICE in $TARGET_DEVICES; do
    SFDISK_OUTPUT="$(sfdisk -d "$DEVICE" 2>/dev/null)"
    if echo "$SFDISK_OUTPUT" |grep -q -E -i '^/dev/.*[[:blank:]]Id=ee' && check_command sgdisk; then
      # GPT partition table:
      SGDISK_OUTPUT="$(sgdisk -p "$DEVICE" 2>/dev/null)"

      if ! echo "$SGDISK_OUTPUT" |grep -q -i -e "GPT: not present"; then
        IFS=$EOL
        echo "$SGDISK_OUTPUT" |grep -E -i "[[:blank:]]8200[[:blank:]]" |while read LINE; do
          NUM="$(echo "$LINE" |awk '{ print $1 }')"
          PART="$(add_partition_number "$DEVICE" "$NUM")"
          if ! mkswap -L "SWAP${SWAP_COUNT}" "$PART"; then
            printf "\033[40m\033[1;31mWARNING: mkswap failed for $PART\n\033[0m" >&2
          fi
          SWAP_COUNT=$(($SWAP_COUNT + 1))
        done
      fi
    else
      # MBR/DOS partition table:
      IFS=$EOL
      echo "$SFDISK_OUTPUT" |grep -i "id=82$" |while read LINE; do
        PART="$(echo "$LINE" |awk '{ print $1 }')"
        if ! mkswap -L "SWAP${SWAP_COUNT}" "$PART"; then
          printf "\033[40m\033[1;31mWARNING: mkswap failed for $PART\n\033[0m" >&2
        fi
        SWAP_COUNT=$(($SWAP_COUNT + 1))
      done
    fi
  done
}


show_help()
{
  echo "Usage: restore-image.sh [options] [image-name]" >&2
  echo "" >&2
  echo "Options:" >&2
  echo "--help|-h                   - Print this help" >&2
  echo "--dev|-d={dev1,dev2}        - Restore image to target device(s) (instead of default from source)." >&2
  echo "                              Optionally use source:/dev/target like sdb:/dev/sda to restore to a different device" >&2
  echo "--part|-p={dev1,dev2}       - Restore only these partitions (instead of all partitions) or \"none\" for no partitions at all." >&2
  echo "                              Optionally use source:/dev/target like sdb1:/dev/sda1 to restore to a different partition" >&2
  echo "--conf|-c={config_file}     - Specify alternate configuration file" >&2
  echo "--noconf                    - Don't read the config file" >&2
  echo "--mbr                       - Always write a new track0(MBR) (from track0.*)" >&2
  echo "--pt                        - Always write a new partition-table (from sfdisk/gdisk.*)" >&2
  echo "--clean                     - Always write track0(MBR)/partition-table/swap-space, even if device is not empty (USE WITH CARE!)" >&2
  echo "--force                     - Continue, even if there are eg. mounted partitions (USE WITH CARE!)" >&2
  echo "--notrack0                  - Never write track0(MBR)/partition-table, even if device is empty" >&2
  echo "--nonet|-n                  - Don't try to setup networking" >&2
  echo "--nomount|-m                - Don't mount anything" >&2
  echo "--noimage                   - Don't restore any partition images, only do partition-table/MBR operations" >&2
  echo "--nocustomsh|--nosh         - Don't execute any custom shell script(s)" >&2
  echo "--onlysh|--sh               - Only execute user (shell) script(s)" >&2
  echo "--add                       - Add partition entries (don't overwrite like with --clean)" >&2
}


load_config()
{
  # Set environment variables to default
  CONF="$DEFAULT_CONF"
  IMAGE_NAME=""
  DEVICES=""
  PARTITIONS=""
  CLEAN=0
  NO_TRACK0=0
  NO_NET=0
  NO_CONF=0
  MBR_WRITE=0
  PT_WRITE=0
  NO_CUSTOM_SH=0
  NO_MOUNT=0
  FORCE=0
  PT_ADD=0
  NO_IMAGE=0
  ONLY_SH=0

  # Check arguments
  unset IFS
  for arg in $*; do
    ARGNAME=`echo "$arg" |cut -d= -f1`
    ARGVAL=`echo "$arg" |cut -d= -f2 -s`

    case "$ARGNAME" in
      --partitions|--partition|--part|-p) PARTITIONS=`echo "$ARGVAL" |sed 's|,| |g'`;; # Make list space seperated
             --devices|--device|--dev|-d) DEVICES=`echo "$ARGVAL" |sed 's|,| |g'`;; # Make list space seperated
                        --clean|--track0) CLEAN=1;;
                                 --force) FORCE=1;;
                              --notrack0) NO_TRACK0=1;;
                               --conf|-c) CONF="$ARGVAL";;
                              --nonet|-n) NO_NET=1;;
                            --nomount|-m) NO_MOUNT=1;;
                                --noconf) NO_CONF=1;;
                                   --mbr) MBR_WRITE=1;;
                                    --pt) PT_WRITE=1;;
                                   --add) PT_ADD=1;;
                     --nocustomsh|--nosh) NO_CUSTOM_SH=1;;
                           --onlysh|--sh) ONLY_SH=1;;
                        --noimage|--noim) NO_IMAGE=1;;
                               --help|-h) show_help;
                                          exit 0
                                          ;;
                                      -*) echo "ERROR: Bad argument \"$arg\"" >&2
                                          show_help;
                                          exit 1;
                                          ;;
                                       *) if [ -z "$IMAGE_NAME" ]; then
                                            IMAGE_NAME="$arg"
                                          else
                                            echo "ERROR: Bad command syntax with argument \"$arg\"" >&2
                                            show_help;
                                            exit 1;
                                          fi
                                          ;;
    esac
  done

  # Check if configuration file exists
  if [ $NO_CONF -eq 0 -a -e "$CONF" ]; then
    # Source the configuration
    . "$CONF"
  fi

  # Translate "long" names to short
  if   [ "$IMAGE_PROGRAM" = "fsarchiver" ]; then
    IMAGE_PROGRAM="fsa"
  elif [ "$IMAGE_PROGRAM" = "partimage" ]; then
    IMAGE_PROGRAM="pi"
  elif [ "$IMAGE_PROGRAM" = "partclone" ]; then
    IMAGE_PROGRAM="pc"
  fi
  
  # Set no_image to true if requested via --part=none
  if [ "$PARTITIONS" = "none" ]; then
    NO_IMAGE=1
  fi
}


#######################
# Program entry point #
#######################
echo "Image RESTORE Script v$MY_VERSION - Written by Arno van Amersfoort"

# Load configuration from file/commandline
load_config $*;

# Sanity check environment
sanity_check;

if [ "$NETWORK" != "none" -a -n "$NETWORK" -a $NO_NET != 1 ]; then
  # Setup network (interface)
  configure_network;

  # Try to sync time against the server used, if ntpdate is available
  if [ -n "$SERVER" ] && check_command ntpdate; then
    ntpdate "$SERVER"
  fi
fi

# Setup CTRL-C handler
trap 'ctrlc_handler' 2

set_image_source_dir;

echo "--------------------------------------------------------------------------------"
echo "* Image name: $(basename $IMAGE_DIR)"
echo "* Image working directory: $(pwd)"

# Make sure we're in the correct working directory:
if ! pwd |grep -q "$IMAGE_DIR$"; then
  printf "\033[40m\033[1;31mERROR: Unable to access image directory ($IMAGE_DIR)!\n\033[0m" >&2
  do_exit 7
fi

# Check for GPT partitions in source
if [ -z "$(find . -maxdepth 1 -type f -iname "sgdisk.*" -o -iname "gdisk.*")" ]; then
  check_command_error gdisk
  check_command_error sgdisk
fi

# Check target disks
check_disks;

if [ $NO_IMAGE -eq 0 ]; then
  check_image_files;
else
  echo "* NOTE: Skipping partition image restoration"
fi

if [ $NO_IMAGE -eq 0 ]; then
  # Check target partitions
  check_partitions;
fi

# Show info about target devices to be used
show_target_devices;

if [ $ONLY_SH -eq 0 ]; then
  if [ $CLEAN -eq 1 ]; then
    echo "* WARNING: MBR/track0 & partition-table will ALWAYS be (over)written (--clean)!" >&2
  else
    if [ $PT_WRITE -eq 1 ]; then
      echo "* WARNING: Partition-table will ALWAYS be (over)written (--pt)!" >&2
    fi

    if [ $MBR_WRITE -eq 1 ]; then
      echo "* WARNING: MBR/track0 will ALWAYS be (over)written (--mbr)!" >&2
    fi
  fi
fi

if [ -e "description.txt" ]; then
  echo "--------------------------------------------------------------------------------"
  cat "description.txt"
fi

echo "--------------------------------------------------------------------------------"
if ! get_user_yn "Continue with restore (Y/N)?"; then
  echo "Aborted by user..."
  do_exit 1;
fi

# Restore MBR/partition tables
if [ $ONLY_SH -eq 0 ]; then
  restore_disks;
fi

if [ $NO_IMAGE -eq 0 -a $ONLY_SH -eq 0 ]; then
  # Make sure the target is sane
  test_target_partitions;

  # Restore images to partitions
  restore_partitions;
fi

if [ $CLEAN -eq 1 -a $ONLY_SH -eq 0 ]; then
  create_swaps;
fi

# Set this for legacy scripts:
TARGET_DEVICE=`echo "$TARGET_DEVICES" |cut -f1 -d' '` # Pick the first device (probably sda)
TARGET_NODEV=`echo "$TARGET_DEVICE" |sed s,'^/dev/',,`
USER_TARGET_NODEV="$TARGET_NODEV"

# Run custom script(s) (should have .sh extension):
if [ $NO_CUSTOM_SH -eq 0 ] && ls *.sh >/dev/null 2>&1; then
  echo "--------------------------------------------------------------------------------"
  unset IFS
  for script in *.sh; do
    if [ -e "$script" ]; then
      # Source script:
      echo "* Executing custom script \"$script\""
      . ./"$script"
    fi
  done
fi

echo "--------------------------------------------------------------------------------"

# Show current partition status.
IFS=' '
for DEVICE in $TARGET_DEVICES; do
  echo "* $DEVICE: $(show_block_device_info "$DEVICE")"
  get_partitions_with_size_type "$DEVICE"
  echo ""
done

echo "* Image restored from: $IMAGE_DIR"

if [ -n "$FAILED" ]; then
  echo "* Partitions restored with errors: $FAILED"
fi

if [ -z "$SUCCESS" ]; then
  echo "* Partitions restored successfully: none"
else
  echo "* Partitions restored successfully: $SUCCESS"
fi

# Exit (+unmount)
do_exit 0
