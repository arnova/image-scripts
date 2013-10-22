#!/bin/bash

MY_VERSION="3.10-BETA15-GPT-DEVEL"
# ----------------------------------------------------------------------------------------------------------------------
# Image Restore Script with (SMB) network support
# Last update: October 22, 2013
# (C) Copyright 2004-2013 by Arno van Amersfoort
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


# $1 = disk device to get partitions from, if not specified all available partitions are listed
get_partitions_with_size()
{
  local DISK_NODEV=`echo "$1" |sed s,'^/dev/',,`

  local FIND_PARTS=`cat /proc/partitions |sed -r -e '1,2d' -e s,'[[blank:]]+/dev/, ,' |awk '{ print $4" "$3 }'`

  if [ -n "$DISK_NODEV" ]; then
    echo "$FIND_PARTS" |grep -E "^${DISK_NODEV}p?[0-9]+"
  else
    echo "$FIND_PARTS" # Show all
  fi
}


# $1 = disk device to get partitions from, if not specified all available partitions are listed
get_partitions()
{
  get_partitions_with_size "$1" |awk '{ print $1 }'
}


# Get partition number from argument and return to stdout
get_partition_number()
{
  echo "$1" |sed -r -e s,'^[/a-z]+',, -e s,'^[0-9]+p',,
}


# Add partition number to device and return to stdout
# $1 = device
# $2 = number
add_partition_number()
{
  if echo "$1" |grep -q '[0-9]'; then
    echo "${1}p${2}"
  else
    echo "${1}${2}"
  fi
}


# Figure out to which disk the specified partition ($1) belongs
get_partition_disk()
{
  echo "$1" |sed -r s,'p?[0-9]+$',,
}


# Get partitions from specified disk
get_disk_partitions()
{
  get_partitions |grep -E -x "${1}p?[0-9]+"
}


show_block_device_info()
{
  local DEVICE=`echo "$1" |sed s,'^/dev/',,`
  
  if ! echo "$DEVICE" |grep -q '^/'; then
    DEVICE="/sys/class/block/${DEVICE}"
  fi

  local VENDOR="$(cat "${DEVICE}/device/vendor" |sed s!' *$'!!g)"
  if [ -n "$VENDOR" ]; then
    printf "%s " "$VENDOR"
  fi

  local MODEL="$(cat "${DEVICE}/device/model" |sed s!' *$'!!g)"
  if [ -n "$MODEL" ]; then
    printf "%s " "$MODEL"
  fi

  local REV="$(cat "${DEVICE}/device/rev" |sed s!' *$'!!g)"
  if [ -n "$REV" ]; then
    printf "%s " "$REV"
  fi

  local SIZE="$(cat "${DEVICE}/size")"
  if [ -n "$SIZE" ]; then
    printf "\t%s GiB" "$(($SIZE / 2 / 1024 / 1024))"
  fi
}


list_device_partitions()
{
  local DEVICE="$1"

  FDISK_OUTPUT="$(fdisk -l "$DEVICE" 2>/dev/null |grep -i -E -e '^/dev/' -e 'Device[[:blank:]]+Boot')"
  # MBR/DOS Partitions:
  IFS=$EOL
  if echo "$FDISK_OUTPUT" |grep -E -i -v '^/dev/.*[[:blank:]]ee[[:blank:]]' |grep -q -E -i '^/dev/'; then
    printf "* DOS partition table:\n${FDISK_OUTPUT}\n\n"
  fi

  if echo "$FDISK_OUTPUT" |grep -q -E -i '^/dev/.*[[:blank:]]ee[[:blank:]]'; then
    # GPT partition table found
    GDISK_OUTPUT="$(gdisk -l "$DEVICE" 2>/dev/null |grep -i -E -e '^[[:blank:]]+[0-9]' -e '^Number')"
    printf "* GPT partition table:\n${GDISK_OUTPUT}\n\n"
  fi
}


# Setup the ethernet interface
configure_network()
{
  IFS=$EOL
  for CUR_IF in `ifconfig -s -a 2>/dev/null |grep -i -v '^iface' |awk '{ print $1 }' |grep -v -e '^dummy0' -e '^bond0' -e '^lo' -e '^wlan'`; do
    IF_INFO=`ifconfig $CUR_IF`
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
        if which dhcpcd >/dev/null 2>&1; then
          echo "* Trying DHCP IP (with dhcpcd) for interface $CUR_IF ($MAC_ADDR)..."
          # Run dhcpcd to get a dynamic IP
          if dhcpcd -L $CUR_IF; then
            continue
          fi
        elif which dhclient >/dev/null 2>&1; then
          echo "* Trying DHCP IP (with dhclient) for interface $CUR_IF ($MAC_ADDR)..."
          if dhclient -1 $CUR_IF; then
            continue
          fi
        fi
      fi

      if echo "$NETWORK" |grep -q -e 'static'; then
        if ! get_user_yn "\n* Setup interface $CUR_IF statically (Y/N)? "; then
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
  if which hdparm >/dev/null 2>&1; then
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
    if which "$cmd" >/dev/null 2>&1; then
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


# Function which waits till the kernel ACTUALLY re-read the partition table
partwait()
{
  local DEVICE="$1"
  
  echo "Waiting for kernel to reread the partition on $DEVICE..."
    
  # Retry several times since some daemons can block the re-reread for a while (like dm/lvm or blkid)
  IFS=' '
  local TRY=10
  while [ $TRY -gt 0 ]; do
    TRY=$(($TRY - 1))

    FAIL=0
    IFS=$EOL
    for LINE in `sfdisk -d "$DEVICE" |grep "^/dev/"`; do
      PART=`echo "$LINE" |awk '{ print $1 }'`
      if echo "$LINE" |grep -i -q "id= 0"; then
        if [ -e "$PART" ]; then
          FAIL=1
          break;
        fi
      else
        if [ ! -e "$PART" ]; then
          FAIL=1
          break;
        fi
      fi
    done
    
    # Sleep 1 second:
    sleep 1
    
    if [ $FAIL -eq 0 ]; then
      return 0
    fi
  done

  printf "\033[40m\033[1;31mWaiting for the kernel to reread the partition FAILED!\n\033[0m" >&2
  return 1
}


# Wrapper for partprobe (call when performing a partition table update with eg. fdisk/sfdisk).
# $1 = Device to re-read
partprobe()
{
  local DEVICE="$1"
  local result=""

  echo "(Re)reading partition-table on $DEVICE..."

  # Retry several times since some daemons can block the re-reread for a while (like dm/lvm or blkid)
  local TRY=10
  while [ $TRY -gt 0 ]; do
    TRY=$(($TRY - 1))

    # Somehow using partprobe here doesn't always work properly, using sfdisk -R instead for now
    result=`sfdisk -R "$DEVICE" 2>&1`
    
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
  
  # Wait till the kernel reread the partition table
  if ! partwait "$DEVICE"; then
    return 2
  fi

  return 0
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

  [ "$NO_NET" != "0" ] && check_command_error ifconfig
  [ "$NO_MOUNT" != "0" ] && check_command_error mount
  [ "$NO_MOUNT" != "0" ] && check_command_error umount

# TODO: Need to do this for GPT implementation but only when GPT is used, so may need to move this
  check_command_warning gdisk
  check_command_warning sgdisk

  # Sanity check devices and check if target devices exist
  IFS=','
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
  IFS=','
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
    printf "\033[40m\033[1;31m\nERROR: Image directory ($IMAGE_DIR) does NOT exist!\n\n\033[0m" >&2
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
          echo "$(basename "$ITEM")"
        done

        printf "\nImage (directory) to use ($IMAGE_DEFAULT): "
        read IMAGE_NAME

        if echo "$IMAGE_NAME" |grep -q "/$"; then
          IMAGE_DIR="$IMAGE_DIR/${IMAGE_NAME%/}"
          IMAGE_DEFAULT="."
          continue;
        fi

        if [ -z "$IMAGE_NAME" ]; then
           IMAGE_NAME="$IMAGE_DEFAULT"
        fi

        if [ "$IMAGE_NAME" = "." -o -z "$IMAGE_NAME" ]; then
          TEMP_IMAGE_DIR="$IMAGE_DIR"
        else
          TEMP_IMAGE_DIR="$IMAGE_DIR/$IMAGE_NAME"
        fi
        
        if ! ls "$TEMP_IMAGE_DIR"/partitions.* >/dev/null 2>&1; then
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
  IFS=' ,'
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
  IFS=' ,'
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
  IFS=' ,'
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
  unset IFS
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
  printf "Select target device (Default=/dev/$DEFAULT_TARGET_NODEV): "
  read USER_TARGET_NODEV

  if [ -z "$USER_TARGET_NODEV" ]; then
    USER_TARGET_NODEV="$DEFAULT_TARGET_NODEV"
  fi

  # Auto remove /dev/ :
  if echo "$USER_TARGET_NODEV" |grep -q '^/dev/'; then
    USER_TARGET_NODEV="$(echo "$USER_TARGET_NODEV" |sed s,'^/dev/',,)"
  fi
}


show_available_disks()
{
  echo "* Available devices/disks:"
  
  IFS=$EOL
  for BLK_DEVICE in /sys/block/*; do
    DEVICE="$(echo "$BLK_DEVICE" |sed s,'^/sys/block/','/dev/',)"
    if echo "$DEVICE" |grep -q -e '/loop[0-9]' -e '/sr[0-9]' -e '/fd[0-9]' -e '/ram[0-9]' || [ ! -e "$DEVICE" -o $(cat "$BLK_DEVICE/size") -eq 0 ]; then
      continue; # Ignore device
    fi

    echo "  $DEVICE: $(show_block_device_info $BLK_DEVICE)"
  done

  echo ""
}


check_disks()
{
  # Reset global, used by other functions later on:
  TARGET_DEVICES=""
  
  # Global used later on when restoring partition-tables etc.
  DEVICE_FILES=""
  
  # Show disks/devices available for restoration
  show_available_disks;

  # Restore MBR/track0/partitions
  # FIXME: need to check track0 + images as well here!?
  # FIXME, we should exclude disks not in --dev, if specified and consider --clean
  unset IFS
  for FN in partitions.*; do
    # Extract drive name from file
    IMAGE_SOURCE_NODEV="$(basename "$FN" |sed s/'.*\.'//)"
    IMAGE_TARGET_NODEV=`source_to_target_remap "$IMAGE_SOURCE_NODEV" |sed s,'^/dev/',,`
    
    echo "* Select target device for image source device /dev/$IMAGE_SOURCE_NODEV"

    while true; do
      user_target_dev_select "$IMAGE_TARGET_NODEV"
      TARGET_NODEV="$USER_TARGET_NODEV"
      
      if [ -z "$TARGET_NODEV" ]; then
        continue;
      fi

      # Check if target device exists
      if [ ! -e "/dev/$TARGET_NODEV" ]; then
        echo ""
        printf "\033[40m\033[1;31mERROR: Target device /dev/$TARGET_NODEV does NOT exist!\n\n\033[0m" >&2
        continue;
      fi

      echo ""

      # Check if DMA is enabled for device
      check_dma "/dev/$TARGET_NODEV"

      # Make sure kernel doesn't use old partition table
      if ! partprobe "/dev/$TARGET_NODEV" && [ $FORCE -ne 1 ]; then
        echo ""
        printf "\033[40m\033[1;31mERROR: Unable to obtain exclusive access on target device /dev/$TARGET_NODEV! Wrong target device specified and/or mounted partitions? Use --force to override.\n\n\033[0m" >&2
        continue;
      fi

      echo ""

      if [ "$IMAGE_TARGET_NODEV" != "$TARGET_NODEV" ]; then
        update_source_to_target_device_remap "$IMAGE_SOURCE_NODEV" "/dev/$TARGET_NODEV"
      fi
      break;
    done

    # Check whether device already contains partitions
    PARTITIONS_FOUND=`get_disk_partitions "$TARGET_NODEV"`

    TRACK0_CLEAN=0
    if [ -z "$PARTITIONS_FOUND" -o $CLEAN -eq 1 ] && [ $NO_TRACK0 -eq 0 ]; then
      TRACK0_CLEAN=1
    fi
    
    if [ -n "$PARTITIONS_FOUND" ]; then
      echo "* NOTE: Target device /dev/$TARGET_NODEV already contains partitions:"
      list_device_partitions /dev/$TARGET_NODEV
    fi

    if [ $PT_ADD -eq 1 ]; then
      # DOS/MBR:
      if [ -f "sfdisk.${IMAGE_SOURCE_NODEV}" ]; then
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
          echo ""

          do_exit 5
        fi
      fi

      # GPT
      if [ -f "gdisk.${IMAGE_SOURCE_NODEV}" ]; then
        GDISK_TARGET="$(gdisk -l "/dev/${TARGET_NODEV}" |grep -E '^[[:blank:]]+[0-9]')"
        if [ -z "$GDISK_TARGET" ]; then
          printf "\033[40m\033[1;31m\nERROR: Unable to get GPT partitions from device /dev/${TARGET_NODEV} ! Quitting...\n\033[0m" >&2
          do_exit 5
        fi

        MISMATCH=0
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
          echo ""

          do_exit 5
        fi
      fi
    fi

    local ENTER=0
    if [ $CLEAN -eq 0 -a -n "$PARTITIONS_FOUND" ]; then
      if [ $PT_WRITE -eq 0 -a $PT_ADD -eq 0 -a $MBR_WRITE -eq 0 ]; then
        echo "" >&2
        printf "\033[40m\033[1;31mWARNING: Since target device /dev/$TARGET_NODEV already has a partition-table/MBR, it will NOT be updated!\n\033[0m" >&2
        echo "To override this you must specify --clean or --pt --mbr..." >&2
        ENTER=1
      else
        if [ $PT_WRITE -eq 0 -a $PT_ADD -eq 0 ]; then
          echo "" >&2
          printf "\033[40m\033[1;31mWARNING: Since target device /dev/$TARGET_NODEV already has a partition-table, it will NOT be updated!\n\033[0m" >&2
          echo "To override this you must specify --clean or --pt..." >&2
          ENTER=1
        fi

        if [ $MBR_WRITE -eq 0 ]; then
          echo "" >&2
          printf "\033[40m\033[1;31mWARNING: Since target device /dev/$TARGET_NODEV already has a partition-table, its MBR will NOT be updated!\n\033[0m" >&2
          echo "To override this you must specify --clean or --mbr..." >&2
          ENTER=1
        fi
      fi
    fi

    if [ $ENTER -eq 1 ]; then
      echo "" >&2
      printf "Press <enter> to continue or CTRL-C to abort...\n" >&2
      read dummy
    fi

    DEVICE_FILES="${DEVICE_FILES}${IMAGE_SOURCE_NODEV}${SEP}${TARGET_NODEV} "
    TARGET_DEVICES="${TARGET_DEVICES}/dev/${TARGET_NODEV} "

    IFS=$EOL
    for PART in $PARTITIONS_FOUND; do
      # Check for mounted partitions on target device
      if grep -E -q "^/dev/${PART}[[:blank:]]" /etc/mtab; then
        echo ""
        if [ $FORCE -eq 1 ]; then
          printf "\033[40m\033[1;31mWARNING: Partition /dev/$PART on target device is mounted!\n\033[0m" >&2
        else
          printf "\033[40m\033[1;31mERROR: Partition /dev/$PART on target device is mounted! Wrong target device specified? Quitting...\n\033[0m" >&2
          do_exit 5
        fi
      fi

      # Check for swap on target device
      if grep -E -q "^/dev/${PART}[[:blank:]]" /proc/swaps; then
        echo ""
        if [ $FORCE -eq 1 ]; then
          printf "\033[40m\033[1;31mWARNING: Partition /dev/$PART on target device is used as swap!\n\033[0m" >&2
        else
          printf "\033[40m\033[1;31mERROR: Partition /dev/$PART on target device is used as swap. Wrong target device specified? Quitting...\n\033[0m" >&2
          do_exit 5
        fi
      fi
    done
  done
}


restore_disks()
{
  # Restore MBR/track0/partitions
  unset IFS
  for ITEM in $DEVICE_FILES; do
    # Extract drive name from file
    IMAGE_SOURCE_NODEV=`echo "$ITEM" |cut -f1 -d"$SEP"`
    TARGET_NODEV=`echo "$ITEM" |cut -f2 -d"$SEP" -s`

    # Check whether device already contains partitions
    PARTITIONS_FOUND=`get_disk_partitions "$TARGET_NODEV"`

    TRACK0_CLEAN=0
    if [ -z "$PARTITIONS_FOUND" -o $CLEAN -eq 1 ] && [ $NO_TRACK0 -eq 0 ]; then
      TRACK0_CLEAN=1
    fi

    # Flag in case we update the mbr/partition-table so we know we need to have the kernel to re-probe
    PARTPROBE=0

    # Check for MBR restore.
    if [ $MBR_WRITE -eq 1 -o $TRACK0_CLEAN -eq 1 ]; then
      DD_SOURCE="track0.${IMAGE_SOURCE_NODEV}"
      if [ ! -f "$DD_SOURCE" ]; then
        echo "WARNING: No $DD_SOURCE found. MBR will be zeroed instead!" >&2
        DD_SOURCE="/dev/zero"
      fi

      echo "* Updating track0(MBR) on /dev/$TARGET_NODEV from $DD_SOURCE"
      
      if [ $CLEAN -eq 1 -o -z "$PARTITIONS_FOUND" ]; then
#        result=`dd if="$DD_SOURCE" of=/dev/$TARGET_NODEV bs=512 count=63 2>&1`
        # For clean or empty disks always try to use a full 1MiB of DD_SOURCE else Grub2 may not work.
        result=`dd if="$DD_SOURCE" of=/dev/$TARGET_NODEV 2>&1 bs=512 count=2048` 
        retval=$?
      else
        # FIXME: Need to detect the empty space before the first partition since Grub2 may be longer than 32256 bytes!
        result=`dd if="$DD_SOURCE" of=/dev/$TARGET_NODEV bs=446 count=1 2>&1 && dd if="$DD_SOURCE" of=/dev/$TARGET_NODEV bs=512 seek=1 skip=1 count=62 2>&1`
        retval=$?
      fi
      
      if [ $retval -ne 0 ]; then
        if [ -n "$result" ]; then
          echo "$result" >&2
        fi
        printf "\033[40m\033[1;31mERROR: Track0(MBR) update from $DD_SOURCE to /dev/$TARGET_NODEV failed($retval). Quitting...\n\033[0m" >&2
        do_exit 5
      fi
      PARTPROBE=1
    fi

    # Check for partition restore
    if [ $PT_WRITE -eq 1 -o $TRACK0_CLEAN -eq 1 -o $PT_ADD -eq 1 ]; then
      SFDISK_FILE=""
      if [ -f "sfdisk.${IMAGE_SOURCE_NODEV}" ]; then
        SFDISK_FILE="sfdisk.${IMAGE_SOURCE_NODEV}"
      elif [ -f "partitions.${IMAGE_SOURCE_NODEV}" ]; then
        SFDISK_FILE="partitions.${IMAGE_SOURCE_NODEV}"
      fi

      if [ -n "$SFDISK_FILE" ]; then
        echo "* Updating DOS partition-table on /dev/$TARGET_NODEV"
        sfdisk --force --no-reread /dev/$TARGET_NODEV < "$SFDISK_FILE"
        retval=$?
          
        if [ $retval -ne 0 ]; then
          printf "\033[40m\033[1;31mDOS partition-table restore failed($retval). Quitting...\n\033[0m" >&2
          echo ""
          do_exit 5
        fi
        PARTPROBE=1
      fi
      
      SGDISK_FILE="sgdisk.${IMAGE_SOURCE_NODEV}"
      if [ -f "$SGDISK_FILE" ]; then
        echo "* Updating GPT partition-table on /dev/$TARGET_NODEV"
        sgdisk --load-backup="$SGDISK_FILE" /dev/$TARGET_NODEV
        retval=$?
          
        if [ $retval -ne 0 ]; then
          printf "\033[40m\033[1;31mGPT partition-table restore failed($retval). Quitting...\n\033[0m" >&2
          echo ""
          do_exit 5
        fi
        PARTPROBE=1
      fi
    fi

    if [ $PARTPROBE -eq 1 ]; then
      echo ""
      # Re-read partition table
      if ! partprobe "/dev/$TARGET_NODEV" && [ $FORCE -ne 1 ]; then
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
      SOURCE_NODEV=`echo "$IMAGE_FILE" |sed 's/\..*//')`
      TARGET_PARTITION=`source_to_target_remap "$SOURCE_NODEV"`
      
      # Add item to list
      IMAGE_FILES="${IMAGE_FILES}${IMAGE_FILES:+ }${IMAGE_FILE}${SEP}${TARGET_PARTITION}"
    done
  else
    IFS=$EOL
    for ITEM in `find . -maxdepth 1 -type f -iname "*.img.gz.000" -o -iname "*.fsa" -o -iname "*.dd.gz" -o -iname "*.pc.gz" |sort`; do
      # FIXME: Can have multiple images here!
      IMAGE_FILE=`basename "$ITEM"`
      SOURCE_NODEV=`echo "$IMAGE_FILE" |sed 's/\..*//'`
      TARGET_PARTITION=`source_to_target_remap "$SOURCE_NODEV"`

      # Add item to list
      IMAGE_FILES="${IMAGE_FILES}${IMAGE_FILES:+ }${IMAGE_FILE}${SEP}${TARGET_PARTITION}"
    done
  fi

  if [ -z "$IMAGE_FILES" ]; then
    printf "\033[40m\033[1;31m\nERROR: No matching image files found to restore! Quitting...\n\033[0m" >&2
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
    PART_DISK=`get_partition_disk "$TARGET_PARTITION"`
    if [ -z "$PART_DISK" ]; then
      echo "* WARNING: Unable to obtain device for target partition $TARGET_PARTITION" >&2
    elif ! echo "$TARGET_DEVICES" |grep -q -e "^$PART_DISK " -e " $PART_DISK " -e " $PART_DISK$" -e "^PART_DISK$"; then
      TARGET_DEVICES="${TARGET_DEVICES}${PART_DISK} "
    fi
    
    # Check for mounted partitions on target device
    if grep -E -q "^${TARGET_PARTITION}[[:blank:]]" /etc/mtab; then
      echo ""
      if [ $FORCE -eq 1 ]; then
        printf "\033[40m\033[1;31mWARNING: Partition /dev/$PART on target device is mounted!\n\033[0m" >&2
      else
        printf "\033[40m\033[1;31mERROR: Partition $TARGET_PARTITION on target device is mounted! Wrong target device specified? Quitting...\n\033[0m" >&2
        do_exit 5
      fi
    fi

    # Check for swaps on this device
    if grep -E -q "^${TARGET_PARTITION}[[:blank:]]" /proc/swaps; then
      echo ""
      if [ $FORCE -eq 1 ]; then
        printf "\033[40m\033[1;31mWARNING: Partition /dev/$PART on target device is used as swap!\n\033[0m" >&2
      else
        printf "\033[40m\033[1;31mERROR: Partition $TARGET_PARTITION on target device is used as swap. Wrong target device specified? Quitting...\n\033[0m" >&2
        do_exit 5
      fi
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


test_target_partitions()
{
  if [ -z "$IMAGE_FILES" ]; then
    return 1 # Nothing to do
  fi

  echo ""

  # Test whether the target partition(s) exist and have the correct geometry:
  local MISMATCH=0
  unset IFS
  for ITEM in $IMAGE_FILES; do
    IMAGE_FILE=$(echo "$ITEM" |cut -f1 -d"$SEP" -s)
    TARGET_PARTITION=$(echo "$ITEM" |cut -f2 -d"$SEP" -s)

    # Strip extension so we get the actual device name
    IMAGE_PARTITION_NODEV=$(echo "$IMAGE_FILE" |sed 's/\..*//')
    SOURCE_DISK_NODEV=$(get_partition_disk "$IMAGE_PARTITION_NODEV")
    TARGET_DISK=$(get_partition_disk "$TARGET_PARTITION")

    SFDISK_TARGET_PART="$(sfdisk -d "$TARGET_DISK" 2>/dev/null |grep -E "^${TARGET_PARTITION}[[:blank:]]")"
    if [ -n "$SFDISK_TARGET_PART" ]; then
      # DOS partition found
      SFDISK_SOURCE_PART="$(grep -E "^/dev/${IMAGE_PARTITION_NODEV}[[:blank:]]" "sfdisk.${SOURCE_DISK_NODEV}" 2>/dev/null)"
      # If empty, try old (legacy) file
      if [ -z "$SFDISK_SOURCE_PART" ]; then
        SFDISK_SOURCE_PART="$(grep -E "^/dev/${IMAGE_PARTITION_NODEV}[[:blank:]]" "partitions.${SOURCE_DISK_NODEV}" 2>/dev/null)"
      fi

      echo "* Source DOS partition: $SFDISK_SOURCE_PART"
      echo "* Target DOS partition: $SFDISK_TARGET_PART"

      # Match partition with what we have stored in our partitions file
      if [ -z "$SFDISK_SOURCE_PART" ]; then
        printf "\033[40m\033[1;31m\nWARNING: DOS partition /dev/$IMAGE_PARTITION_NODEV can not be found in the partition source  files!\n\033[0m" >&2
        echo ""
        MISMATCH=1
        continue;
      fi

      # Check geometry/type of partition
      if [ "$(echo "$SFDISK_TARGET_PART" |sed -r -e s,'^/dev/[a-z]+',, -e s,'^[0-9]+p',,)" != "$(echo "$SFDISK_SOURCE_PART" |sed -r -e s,'^/dev/[a-z]+',, -e s,'^[0-9]+p',,)" ]; then
        MISMATCH=1
      fi
    else
      GDISK_TARGET_PART="$(gdisk -l "$TARGET_DISK" |grep -E "^[[:blank:]]+$(get_partition_number "$TARGET_PARTITION")[[:blank:]]")"
      if [ -n "$SGDISK_TARGET_PART" ]; then
        SGDISK_SOURCE_PART="$(grep -E "^[[:blank:]]+$(get_partition_number "$IMAGE_PARTITION_NODEV")[[:blank:]]" "sgdisk.${SOURCE_DISK_NODEV}" 2>/dev/null)"

        echo "* Source GPT partition: $SGDISK_SOURCE_PART"
        echo "* Target GPT partition: $SGDISK_TARGET_PART"

        # Match partition with what we have stored in our partitions file
        if [ -z "$SGDISK_SOURCE_PART" ]; then
          printf "\033[40m\033[1;31m\nWARNING: GPT partition /dev/$IMAGE_PARTITION_NODEV can not be found in partition source files!\n\033[0m" >&2
          echo ""
          MISMATCH=1
          continue;
        fi

        if [ "$SGDISK_TARGET_PART" != "$SGDISK_SOURCE_PART" ]; then
          MISMATCH=1
        fi
      else
        printf "\033[40m\033[1;31m\nERROR: Unable to detect target partition $TARGET_PARTITION! Quitting...\n\033[0m" >&2
        do_exit 5
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


create_swaps()
{
  # Create swap on swap partitions on all used devices

  local SWAP_COUNT=0

  IFS=' '
  for DEVICE in $TARGET_DEVICES; do
    SFDISK_OUTPUT="$(sfdisk -d "$DEVICE" 2>/dev/null)"
    # MBR/DOS Partitions:
    IFS=$EOL
    echo "$SFDISK_OUTPUT" |grep -i "id=82$" |while read LINE; do
      PART="$(echo "$LINE" |awk '{ print $1 }')"
      if ! mkswap -L "SWAP${SWAP_COUNT}" "$PART"; then
        printf "\033[40m\033[1;31mWARNING: mkswap failed for $PART\n\033[0m" >&2
      fi
      SWAP_COUNT=$(($SWAP_COUNT + 1))
    done
    
    if echo "$SFDISK_OUTPUT" |grep -q -E -i '^/dev/.*[[:blank:]]Id=ee'; then
      # GPT partition table found
      SGDISK_OUTPUT="$(sgdisk -p "$DEVICE" 2>/dev/null)"

      if ! echo "$SGDISK_OUTPUT" |grep -q -i -e "GPT: not present"; then
        IFS=$EOL
        echo "$SGDISK_OUTPUT" |grep -E -i "[[:blank:]]8200[[:blank:]]+Linux swap" |while read LINE; do
          NUM="$DEVICE/$(echo "$LINE" |awk '{ print $1 }')"
          PART="$(add_partition_number "$DEVICE" "$NUM")"
          if ! mkswap -L "SWAP${SWAP_COUNT}" "$PART"; then
            printf "\033[40m\033[1;31mWARNING: mkswap failed for $PART\n\033[0m" >&2
          fi
          SWAP_COUNT=$(($SWAP_COUNT + 1))
        done
      fi
    fi
  done
}


show_help()
{
  echo "Usage: restore-image.sh [options] [image-name]" >&2
  echo "" >&2
  echo "Options:" >&2
  echo "--help|-h                   - Print this help" >&2
  echo "--dev|-d={dev1,dev2}        - Restore image to target device(s) (instead of default). Optionally use source:/dev/target" >&2
  echo "                              like sdb:/dev/sda or sdb1:/dev/sda to restore to a different device/partition" >&2
  echo "--part|-p={dev1,dev2}       - Restore only these partitions (instead of all partitions) or \"none\" for no partitions at all" >&2
  echo "--conf|-c={config_file}     - Specify alternate configuration file" >&2
  echo "--noconf                    - Don't read the config file" >&2
  echo "--mbr                       - Always write a new track0(MBR) (from track0.*)" >&2
  echo "--pt                        - Always write a new partition-table (from partitions.*)" >&2
  echo "--clean                     - Always write track0(MBR)/partition-table/swap-space, even if device is not empty (USE WITH CARE!)" >&2
  echo "--force                     - Continue, even if there are eg. mounted partitions (USE WITH CARE!)" >&2
  echo "--notrack0                  - Never write track0(MBR)/partition-table, even if device is empty" >&2
  echo "--nonet|-n                  - Don't try to setup networking" >&2
  echo "--nomount|-m                - Don't mount anything" >&2
  echo "--noimage                   - Don't restore any partition images, only do partition-table/MBR operations" >&2
  echo "--noccustomsh|--nosh        - Don't execute any custom shell script(s)" >&2
  echo "--onlysh|--sh               - Only execute user (shell) script(s)" >&2
  echo "--add                       - Add partition entries (don't overwrite like with --clean)" >&2
}


load_config()
{
  # Set environment variables to default
  CONF="$DEFAULT_CONF"
  IMAGE_NAME=""
  SUCCESS=""
  FAILED=""
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
      --partitions|--partition|--part|-p) PARTITIONS="$ARGVAL";;
             --devices|--device|--dev|-d) DEVICES="$ARGVAL";;
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
                                      -*) echo "Bad argument: $ARGNAME" >&2
                                          show_help;
                                          exit 0
                                          ;;
                                       *) if [ -z "$IMAGE_NAME" ]; then
                                            IMAGE_NAME="$arg"
                                          else
                                            echo "Bad command syntax" >&2
                                            show_help;
                                            exit 4
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

if [ "$NETWORK" != "none" -a -n "$NETWORK" -a "$NO_NET" != "1" ]; then
  # Setup network (interface)
  configure_network;

  # Try to sync time against the server used, if ntpdate is available
  if which ntpdate >/dev/null 2>&1 && [ -n "$SERVER" ]; then
    ntpdate "$SERVER"
    echo ""
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
    if [ -f "$script" ]; then
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
  list_device_partitions "$DEVICE"
done

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
