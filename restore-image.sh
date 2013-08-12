# !/bin/bash

MY_VERSION="3.10-BETA9"
# ----------------------------------------------------------------------------------------------------------------------
# Image Restore Script with (SMB) network support
# Last update: August 12, 2013
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
        if which dhclient >/dev/null 2>&1; then
          printf "* Trying DHCP IP (with dhclient) for interface $CUR_IF ($MAC_ADDR)..."
          if ! dhclient -v -1 $CUR_IF; then
            echo "FAILED!"
          else
            echo "OK"
            continue
          fi
        elif which dhcpcd >/dev/null 2>&1; then
          printf "* Trying DHCP IP (with dhcpcd) for interface $CUR_IF ($MAC_ADDR)..."
          # Run dhcpcd to get a dynamic IP
          if ! dhcpcd -L $CUR_IF; then
            echo "FAILED!"
          else
            echo "OK"
            continue
          fi
        fi
      fi

      if echo "$NETWORK" |grep -q -e 'static'; then
        if ! get_user_yn "Setup interface $CUR_IF statically (Y/N)?"; then
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

    echo ""
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


sanity_check()
{
  # root check
  if [ "$(id -u)" != "0" ]; then 
    printf "\033[40m\033[1;31mERROR: Root check FAILED (you MUST be root to use this script)! Quitting...\033[0m\n" >&2
    exit 1
  fi

  check_command_error awk
  check_command_error find
  check_command_error ifconfig
  check_command_error sed
  check_command_error grep
  check_command_error mkswap
  check_command_error sfdisk
  check_command_error fdisk
  check_command_error dd
  check_command_error mount
  check_command_error umount
  check_command_error parted

# TODO: Need to do this for GPT implementation
#  check_command_error gdisk
#  check_command_error sgdisk

  # Sanity check devices and check if target devices exist
  IFS=','
  for ITEM in $DEVICES; do
    SOURCE_DEVICE_NODEV=`echo "$ITEM" |cut -f1 -d"$SEP"`
    TARGET_DEVICE_MAP=`echo "$ITEM" |cut -f2 -d"$SEP" -s`

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

    if ! get_partitions |grep -q -x "$CHECK_DEVICE_NODEV"; then
      echo ""
      printf "\033[40m\033[1;31mERROR: Specified (target) device /dev/$CHECK_DEVICE_NODEV does NOT exist! Quitting...\n\033[0m" >&2
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


get_partitions_with_size()
{
  cat /proc/partitions |sed -e '1,2d' -e 's,^/dev/,,' |awk '{ print $4" "$3 }'
}


get_partitions()
{
  get_partitions_with_size |awk '{ print $1 }'
}


parted_list_fancy()
{
  local DEV="$1"
  local FOUND=0
  local MATCH=0

  IFS=$EOL
  for LINE in `parted -l 2>/dev/null |sed s,'.*\r',,`; do # NOTE: The sed is there to fix a bug(?) in parted causing an \r to appear on stdout in case of errors output to stderr
    if echo "$LINE" |grep -q '^Model: '; then
      MATCH=0
      MODEL="$LINE"
    elif echo "$LINE" |grep -q '^Disk /dev/'; then
      # Match disk
      if echo "$LINE" |grep -q "^Disk $DEV: "; then
        echo "$LINE"
        echo "$MODEL"
        FOUND=1
        MATCH=1
      fi
    elif [ $MATCH -eq 1 ]; then
      echo "$LINE"
    fi
  done

  if [ $FOUND -eq 0 ]; then
    echo "WARNING: Parted was unable to retrieve information for device $DEV!" >&2
  fi
}


parted_list()
{
  local DEV="$1"
  local FOUND=0
  local MATCH=0
  local TYPE=""

  IFS=$EOL
  for LINE in `parted --list --machine 2>/dev/null |sed s,'.*\r',,`; do # NOTE: The sed is there to fix a bug(?) in parted causing an \r to appear on stdout in case of errors output to stderr
    if ! echo "$LINE" |grep -q ':'; then
      TYPE="$LINE"
      MATCH=0
    fi

    if echo "$LINE" |grep -q "^$DEV:"; then
      echo "$TYPE"
      FOUND=1
      MATCH=1
    fi

    if [ $MATCH -eq 1 ]; then
      echo "$LINE"
    fi
  done

  if [ $FOUND -eq 0 ]; then
    echo "WARNING: Parted was unable to retrieve information for device $DEV!" >&2
  fi
}


chdir_safe()
{
  local IMAGE_DIR="$1"
  
  if [ ! -d "$IMAGE_DIR" ]; then
    printf "\033[40m\033[1;31m\nERROR: Image directory ($IMAGE_DIR) does NOT exist!\n\n\033[0m" >&2
    return 1
  fi
  
  # Make the image dir our working directory
  if ! cd "$IMAGE_DIR"; then
    printf "\033[40m\033[1;31mERROR: Unable to cd to image directory $IMAGE_DIR!\n\033[0m" >&2
    return 2
  fi

  return 0
}


# Function which waits till the kernel ACTUALLY re-read the partition table
partwait()
{
  local DEVICE="$1"
  
  printf "Waiting for kernel to reread the partition on $DEVICE"
    
  # Retry several times since some daemons can block the re-reread for a while (like dm/lvm or blkid)
  for x in `seq 1 10`; do
    printf "."
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
      echo " Done."
      return 0
    fi
  done

  echo " FAIL!"
  printf "\033[40m\033[1;31mWaiting for the kernel to reread the partition timed out!\n\033[0m" >&2
  return 1
}


# Wrapper for partprobe (call when performing a partition table update with eg. fdisk/sfdisk).
# $1 = Device to re-read
partprobe()
{
  local DEVICE="$1"
  local result=""

  printf "(Re)reading partition-table on $DEVICE"
  
  # Retry several times since some daemons can block the re-reread for a while (like dm/lvm or blkid)
  for x in `seq 1 10`; do
    printf "."
    
    # Somehow using partprobe here doesn't always work properly, using sfdisk -R instead for now
    result=`sfdisk -R "$DEVICE" 2>&1`
    
    # Wait a bit for things to settle
    sleep 1
    
    if [ -z "$result" ]; then
      break;
    fi
  done
  
  if [ -n "$result" ]; then
    echo " FAIL!"
    printf "\033[40m\033[1;31m${result}\n\033[0m" >&2
    return 1
  fi
  
  echo " Done."
  
  # Wait till the kernel reread the partition table
  if ! partwait "$DEVICE"; then
    return 2
  fi
  
  return 0
}


set_image_dir()
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


image_to_target_remap()
{
  local IMAGE_PARTITION_NODEV=`echo "$1" |sed 's/\..*//'`
      
  # Set default
  local TARGET_PARTITION="/dev/$IMAGE_PARTITION_NODEV"

  # We want another target device than specified in the image name?:
  IFS=','
  for ITEM in $DEVICES; do
    SOURCE_DEVICE_NODEV=`echo "$ITEM" |cut -f1 -d"$SEP"`
    TARGET_DEVICE_MAP=`echo "$ITEM" |cut -f2 -d"$SEP" -s`

    if echo "$IMAGE_PARTITION_NODEV" |grep -E -x -q "${SOURCE_DEVICE_NODEV}p?[0-9]+" && [ -n "$TARGET_DEVICE_MAP" ]; then
      NUM=`echo "$IMAGE_PARTITION_NODEV" |sed -r -e 's,^[a-z]*,,' -e 's,^.*p,,'`
      TARGET_DEVICE_MAP_NODEV=`echo "$TARGET_DEVICE_MAP" |sed s,'^/dev/',,`
      TARGET_PARTITION="/dev/$(get_partitions |grep -E -x -e "${TARGET_DEVICE_MAP_NODEV}p?${NUM}")"
      break;
    fi
  done

  # We want another target partition than specified in the image name?:
  IFS=','
  for ITEM in $PARTITIONS; do
    SOURCE_PARTITION_NODEV=`echo "$ITEM" |cut -f1 -d"$SEP"`
    TARGET_PARTITION_MAP=`echo "$ITEM" |cut -f2 -d"$SEP" -s`

    if [ "$SOURCE_PARTITION_NODEV" = "$IMAGE_PARTITION_NODEV" -a -n "$TARGET_PARTITION_MAP" ]; then
      TARGET_PARTITION="$TARGET_PARTITION_MAP"
      break;
    fi
  done
  
  echo "$TARGET_PARTITION"
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


check_disks()
{
  # Reset global, used by other functions later on:
  TARGET_DEVICES=""
  
  # Global used later on when restoring partition-tables etc.
  DEVICE_FILES=""

  # Restore MBR/track0/partitions
  unset IFS
  # FIXME: need to check track0 + images as well here!?
  # FIXME, we should exclude disks not in --dev, if specified and consider --clean
  for FN in partitions.*; do
    # Extract drive name from file
    IMAGE_SOURCE_NODEV="$(basename "$FN" |sed s/'.*\.'//)"
    TARGET_NODEV="$IMAGE_SOURCE_NODEV"

    # Overrule target device?:
    # We want another target device than specified in the image name?:
    IFS=','
    for ITEM in $DEVICES; do
      SOURCE_DEVICE_NODEV=`echo "$ITEM" |cut -f1 -d"$SEP"`
      TARGET_DEVICE_MAP=`echo "$ITEM" |cut -f2 -d"$SEP" -s`

      if [ "$SOURCE_DEVICE_NODEV" = "$IMAGE_SOURCE_NODEV" ]; then
        TARGET_NODEV=`echo "$TARGET_DEVICE_MAP" |sed s,'^/dev/',,`
        break;
      fi
    done

    # Check if target device exists
    if ! get_partitions |grep -q -x "$TARGET_NODEV"; then
      echo ""
      printf "\033[40m\033[1;31mERROR: Target device /dev/$TARGET_NODEV does NOT exist! Quitting...\n\033[0m" >&2
      do_exit 5
    fi

    echo ""

    # Check if DMA is enabled for device
    check_dma "/dev/$TARGET_NODEV"

    # Make sure kernel doesn't use old partition table
    if ! partprobe "/dev/$TARGET_NODEV" && [ $FORCE -ne 1 ]; then
      echo ""
      parted_list_fancy "/dev/$TARGET_NODEV" |grep -e '^Disk /dev/' -e 'Model: ' |sed s,'^',' ',
      printf "\033[40m\033[1;31mERROR: Unable to obtain exclusive access on target device /dev/$TARGET_NODEV! Wrong target device specified and/or mounted partitions? Use --force to override. Quitting...\n\033[0m" >&2
      do_exit 5;
    fi
    echo ""

    # Check whether device already contains partitions
    PARTITIONS_FOUND=`get_partitions |grep -E -x "${TARGET_NODEV}p?[0-9]+"`

    TRACK0_CLEAN=0
    if [ -z "$PARTITIONS_FOUND" -o $CLEAN -eq 1 ] && [ $NO_TRACK0 -eq 0 ]; then
      TRACK0_CLEAN=1
    fi
    
    if [ -n "$PARTITIONS_FOUND" ]; then
      echo "* NOTE: Target device /dev/$TARGET_NODEV already contains partitions:"
      parted_list_fancy /dev/$TARGET_NODEV |grep '^ '
      echo ""
    fi

    if [ $TRACK0_CLEAN -eq 0 ] && [ $NO_TRACK0 -eq 0 ] && [ $PT_WRITE -eq 0 -o $MBR_WRITE -eq 0 ]; then
      echo "" >&2

      if [ $PT_WRITE -eq 0 -a $MBR_WRITE -eq 0 ]; then
        printf "\033[40m\033[1;31mWARNING: Since target device /dev/$TARGET_NODEV already has a partition-table/MBR, it will NOT be updated!\n\033[0m" >&2
        echo "To override this you must specify --clean or --pt --mbr..." >&2
      else
        if [ $PT_WRITE -eq 0 ]; then
          printf "\033[40m\033[1;31mWARNING: Since target device /dev/$TARGET_NODEV already has a partition-table, it will NOT be updated!\n\033[0m" >&2
          echo "To override this you must specify --clean or --pt..." >&2
        fi

        if [ $MBR_WRITE -eq 0 ]; then
          printf "\033[40m\033[1;31mWARNING: Since target device /dev/$TARGET_NODEV already has a partition-table, its MBR will NOT be updated!\n\033[0m" >&2
          echo "To override this you must specify --clean or --mbr..." >&2
        fi
      fi

      echo "" >&2
      printf "Press <enter> to continue or CTRL-C to abort...\n" >&2
      read dummy

      continue;
    fi

    TARGET_DEVICES="${TARGET_DEVICES}/dev/${TARGET_NODEV} "
    DEVICE_FILES="${DEVICE_FILES}${IMAGE_SOURCE_NODEV}${SEP}${TARGET_NODEV} "

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
    PARTITIONS_FOUND=`get_partitions |grep -E -x "${TARGET_NODEV}p?[0-9]+"`

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
    if [ $PT_WRITE -eq 1 -o $TRACK0_CLEAN -eq 1 ]; then
      if [ -f "partitions.${IMAGE_SOURCE_NODEV}" ]; then
        echo "* Updating partition-table on /dev/$TARGET_NODEV"
        sfdisk --force --no-reread /dev/$TARGET_NODEV < "partitions.${IMAGE_SOURCE_NODEV}"
        retval=$?
          
        if [ $retval -ne 0 ]; then
          printf "\033[40m\033[1;31mPartition-table restore failed($retval). Quitting...\n\033[0m" >&2
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
      TARGET_PARTITION=`image_to_target_remap "$IMAGE_FILE"`
      
      # Add item to list
      IMAGE_FILES="${IMAGE_FILES}${IMAGE_FILES:+ }${IMAGE_FILE}${SEP}${TARGET_PARTITION}"
    done
  else
    IFS=$EOL
    for ITEM in `find . -maxdepth 1 -type f -iname "*.img.gz.000" -o -iname "*.fsa" -o -iname "*.dd.gz" -o -iname "*.pc.gz" |sort`; do
      # FIXME: Can have multiple images here!
      IMAGE_FILE=`basename "$ITEM"`
      TARGET_PARTITION=`image_to_target_remap "$IMAGE_FILE"`

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
                  if check_command pigz; then
                    GZIP="pigz"
                  elif check_command_error gzip; then
                    GZIP="gzip"
                  fi
                  ;;
      ddgz      ) if check_command pigz; then
                    GZIP="pigz"
                  elif check_command_error gzip; then
                    GZIP="gzip"
                  fi
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

    # Check whether we need to add this to our included devices list
    PART_DEV=`echo "$TARGET_PARTITION" |sed -r 's,p?[0-9]*$,,'`
    if [ -z "$PART_DEV" ]; then
      echo "* WARNING: Unable to obtain device for target partition $TARGET_PARTITION" >&2
    else
      if ! echo "$TARGET_DEVICES" |grep -q -e "^$PART_DEV " -e " $PART_DEV " -e " $PART_DEV$" -e "^PART_DEV$"; then
        TARGET_DEVICES="${TARGET_DEVICES}${PART_DEV} "
      fi
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

    echo "* Using image file \"${IMAGE_FILE}\" for partition $TARGET_PARTITION"
  done

  return 0
}


show_target_devices()
{
  IFS=' '
  for DEV in $TARGET_DEVICES; do
    echo "* Using (target) device:"
    parted_list_fancy $DEV |grep -e '^Disk /dev/' -e 'Model: ' |sed s,'^',' ',
    echo ""
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
    IMAGE_FILE=`echo "$ITEM" |cut -f1 -d"$SEP" -s`
    TARGET_PARTITION=`echo "$ITEM" |cut -f2 -d"$SEP" -s`

    # Strip extension so we get the actual device name
    IMAGE_PARTITION_NODEV="$(echo "$IMAGE_FILE" |sed 's/\..*//')"

    SFDISK_TARGET_PART=`sfdisk -d 2>/dev/null |grep -E "^${TARGET_PARTITION}[[:blank:]]"`
    if [ -z "$SFDISK_TARGET_PART" ]; then
      printf "\033[40m\033[1;31m\nERROR: Target partition $TARGET_PARTITION does NOT exist! Quitting...\n\033[0m" >&2
      do_exit 5
    fi

    SFDISK_SOURCE_PART=`cat partitions.* |grep -E "^/dev/${IMAGE_PARTITION_NODEV}[[:blank:]]"`

    echo "* Source partition: $SFDISK_SOURCE_PART"
    echo "* Target partition: $SFDISK_TARGET_PART"

    # Match partition with what we have stored in our partitions file
    if [ -z "$SFDISK_SOURCE_PART" ]; then
      printf "\033[40m\033[1;31m\nWARNING: Partition /dev/$IMAGE_PARTITION_NODEV can not be found in the partitions.* files!\n\033[0m" >&2
      echo ""
      MISMATCH=1
      continue;
    fi

    if ! echo "$SFDISK_TARGET_PART" |grep -q "$(echo "$SFDISK_SOURCE_PART" |sed -r s,"^/dev/${IMAGE_PARTITION_NODEV}[[:blank:]]","",)"; then
      MISMATCH=1
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
  # Run mkswap on swap partitions
  IFS=' '
  for DEVICE in $TARGET_DEVICES; do
    # Create swap on swap partitions on all used devices
    IFS=$EOL
    sfdisk -d "$DEVICE" 2>/dev/null |grep -i "id=82$" |while read LINE; do
      PART="$(echo "$LINE" |awk '{ print $1 }')"
      if ! mkswap $PART; then
        printf "\033[40m\033[1;31mWARNING: mkswap failed for $PART\n\033[0m" >&2
      fi
    done
  done
}


show_help()
{
  echo "Usage: restore-image.sh [options] [image-name]"
  echo ""
  echo "Options:"
  echo "--help|-h                   - Print this help"
  echo "--part|-p={dev1,dev2}       - Restore only these partitions (instead of all partitions) or \"none\" for no partitions at all"
  echo "--conf|-c={config_file}     - Specify alternate configuration file"
  echo "--noconf                    - Don't read the config file"
  echo "--mbr                       - Always write a new track0(MBR) (from track0.*)"
  echo "--pt                        - Always write a new partition-table (from partitions.*)"
  echo "--clean                     - Always write track0(MBR)/partition-table/swap-space, even if device is not empty (USE WITH CARE!)"
  echo "--force                     - Continue, even if there are eg. mounted partitions (USE WITH CARE!)"
  echo "--notrack0                  - Never write track0(MBR)/partition-table, even if device is empty"
  echo "--dev|-d={dev}              - Restore image to target device {dev} (instead of default)"
  echo "--nonet|-n                  - Don't try to setup networking"
  echo "--nomount|-m                - Don't mount anything"
  echo "--noimage                   - Don't restore any images, only do partition/MBR operations"
  echo "--nopostsh|--nosh           - Don't execute any post image shell scripts"
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
  NO_POST_SH=0
  NO_MOUNT=0
  FORCE=0

  # Check arguments
  unset IFS
  for arg in $*; do
    ARGNAME=`echo "$arg" |cut -d= -f1`
    ARGVAL=`echo "$arg" |cut -d= -f2 -s`

    case "$ARGNAME" in
      --clean|--track0) CLEAN=1;;
      --force) FORCE=1;;
      --notrack0) NO_TRACK0=1;;
      --devices|--device|--dev|-d) DEVICES="$ARGVAL";;
      --partitions|--partition|--part|-p) PARTITIONS="$ARGVAL";;
      --conf|-c) CONF="$ARGVAL";;
      --nonet|-n) NO_NET=1;;
      --nomount|-m) NO_MOUNT=1;;
      --noconf) NO_CONF=1;;
      --mbr) MBR_WRITE=1;;
      --pt) PT_WRITE=1;;
      --nopostsh|--nosh) NO_POST_SH=1;;
      --help|-h) show_help; exit 3;;
      -*) echo "Bad argument: $ARGNAME" >&2
          show_help
          exit 4
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

set_image_dir;

echo "--------------------------------------------------------------------------------"
echo "* Image name: $(basename $IMAGE_DIR)"
echo "* Image working directory: $(pwd)"

# Make sure we're in the correct working directory:
if ! pwd |grep -q "$IMAGE_DIR$"; then
  printf "\033[40m\033[1;31mERROR: Unable to access image directory ($IMAGE_DIR)!\n\033[0m" >&2
  do_exit 7
fi

if [ "$PARTITIONS" = "none" ]; then
  echo "* NOTE: Skipping partition image restoration"
else
  check_image_files;
fi

# Check target disks
check_disks;

# Check target partitions
check_partitions;

# Show info about target devices to be used
show_target_devices;

if [ $CLEAN -eq 1 ]; then
  echo "* WARNING: MBR/track0, partition-table & swap-space will ALWAYS be (over)written (--clean)!" >&2
else
  if [ $PT_WRITE -eq 1 ]; then
    echo "* WARNING: Partition-table will ALWAYS be (over)written (--pt)!" >&2
  fi

  if [ $MBR_WRITE -eq 1 ]; then
    echo "* WARNING: MBR/track0 will ALWAYS be (over)written (--mbr)!" >&2
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
restore_disks;

# Make sure the target is sane
test_target_partitions;
 
# Restore images to partitions
if [ "$PARTITIONS" != "none" ]; then
  restore_partitions;
fi

if [ $CLEAN -eq 1 ]; then
  create_swaps;
fi

# Set this for legacy scripts:
TARGET_DEVICE=`echo "$TARGET_DEVICES" |cut -f1 -d' '` # Pick the first device as target (probably sda)
TARGET_NODEV=`echo "$TARGET_DEVICE" |sed s,'^/dev/',,`
USER_TARGET_NODEV="$TARGET_NODEV"

# Run custom script(s) (should have .sh extension):
if [ $NO_POST_SH -eq 0 ]; then
  unset IFS
  for script in *.sh; do
    if [ -f "$script" ]; then
      # Source script:
      . ./"$script"
    fi
  done
fi

echo "--------------------------------------------------------------------------------"

# Show current partition status.
IFS=' '
for DEVICE in $TARGET_DEVICES; do
  parted_list_fancy "$DEVICE"
  echo ""
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
