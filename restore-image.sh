# !/bin/bash

MY_VERSION="3.10-BETA"
# ----------------------------------------------------------------------------------------------------------------------
# Image Restore Script with (SMB) network support
# Last update: April 17, 2013
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
EOL='
'

do_exit()
{
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
  local CUR_IF=""
  local IP_SET=""
  local MAC_ADDR=""

  IFS=$EOL
  for LINE in $(ifconfig -a 2>/dev/null); do
    if echo "$LINE" |grep -q -i 'Link encap'; then
      CUR_IF="$(echo "$LINE" |grep -i 'link encap:ethernet' |grep -v -e '^dummy0' -e '^bond0' -e '^lo' -e '^wlan' |cut -f1 -d' ')"
      MAC_ADDR="$(echo "$LINE" |awk '{ print $NF }')"
    elif echo "$LINE" |grep -q -i 'inet addr:.*Bcast.*Mask.*'; then
      IP_SET="$(echo "$LINE" |sed 's/^ *//g')"
    elif echo "$LINE" |grep -q -i '.*RX packets.*'; then
      if [ -n "$CUR_IF" ]; then
        if [ -z "$IP_SET" ] || ! ifconfig 2>/dev/null |grep -q -e "^$CUR_IF[[:blank:]]"; then
          echo "* Network interface $CUR_IF is not active (yet)"
          
          if echo "$NETWORK" |grep -q -e 'dhcp'; then
            if which dhcpcd >/dev/null 2>&1; then
              printf "* Trying DHCP IP (with dhcpcd) for interface $CUR_IF ($MAC_ADDR)..."
              # Run dhcpcd to get a dynamic IP
              if ! dhcpcd -L $CUR_IF; then
                echo "FAILED!"
              else
                echo "OK"
                continue
              fi
            elif which dhclient >/dev/null 2>&1; then
              printf "* Trying DHCP IP (with dhclient) for interface $CUR_IF ($MAC_ADDR)..."
              if ! dhclient -v -1 $CUR_IF; then
                echo "FAILED!"
              else
                echo "OK"
                continue
              fi
            fi
          fi
            
          if echo "$NETWORK" |grep -q -e 'static'; then
            printf "Setup interface $CUR_IF statically (Y/N)? "
            
            read answer
            if [ "$answer" = "n" -o "$answer" = "N" ]; then
              continue
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
          echo "  $IP_SET"
        fi
      fi
      CUR_IF=""
      IP_SET=""
      MAC_ADDR=""
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

# TODO: Need to do this for GPT implementation  
#  check_command_error gdisk
#  check_command_error sgdisk
}


get_partitions_with_size()
{
  cat /proc/partitions |sed -e '1,2d' -e 's,^/dev/,,' |awk '{ print $4" "$3 }'
}


get_partitions()
{
  get_partitions_with_size |awk '{ print $1 }'
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

  printf "(Re)reading partition table on $DEVICE"
  
  # Retry several times since some daemons can block the re-reread for a while (like dm/lvm or blkid)
  for x in `seq 1 10`; do
    printf "."  
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

      if [ -n "$NETWORK" -a "$NETWORK" != "none" -a -n "$DEFAULT_USERNAME" ]; then
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
      if [ -z "$IMAGE_ROOT" ]; then
        # Default to the cwd
        IMAGE_ROOT="."
      fi
      
      IMAGE_DIR="$IMAGE_ROOT"
      
      # Ask user for IMAGE_NAME:
      while true; do
        echo "* Showing contents of the image root directory ($IMAGE_DIR):"
        IFS=$EOL
        find "$IMAGE_DIR" -mindepth 1 -maxdepth 1 -type d |while read ITEM; do
          echo "$(basename "$ITEM")"
        done

        printf "\nImage to use ($IMAGE_RESTORE_DEFAULT): "
        read IMAGE_NAME
        
        if [ -z "$IMAGE_NAME" -a -n "$IMAGE_RESTORE_DEFAULT" ]; then
          IMAGE_NAME="$IMAGE_RESTORE_DEFAULT"
        fi
        
        if [ -z "$IMAGE_NAME" ]; then
          printf "\033[40m\033[1;31m\nERROR: No image directory specified!\n\n\033[0m" >&2
          continue;
        fi

        # Set the directory where the image(s) are
        IMAGE_DIR="$IMAGE_ROOT/$IMAGE_NAME"

        if echo "$IMAGE_DIR" |grep -q "/$"; then
          continue;
        fi
        
        if ! chdir_safe "$IMAGE_DIR"; then
          IMAGE_DIR="$IMAGE_ROOT"
          continue;
        fi
        
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


restore_partitions()
{
  # Restore the actual image(s):
  unset IFS
  for IMAGE_FILE in $IMAGE_FILES; do
    # Strip extension so we get the actual device name
    PARTITION="$(echo "$IMAGE_FILE" |sed 's/\..*//')"

    # We want another target device than specified in the image name?:
    if [ -n "$USER_TARGET_NODEV" ]; then
      NUM="$(echo "$PARTITION" |sed -e 's,^[a-z]*,,' -e 's,^.*p,,')"
      TARGET_PART_NODEV="$(get_partitions |grep -E -x -e "${USER_TARGET_NODEV}p?${NUM}")"
    else
      TARGET_PART_NODEV="$PARTITION"
    fi

    echo "* Selected partition: /dev/$TARGET_PART_NODEV. Using image file: $IMAGE_FILE"
    local retval=1
    case $(image_type_detect "$IMAGE_FILE") in
      fsarchiver) fsarchiver -v restfs "$IMAGE_FILE" id=0,dest="/dev/$TARGET_PART_NODEV"
                  retval=$?
                  ;;
      partimage)  partimage -b restore "/dev/$TARGET_PART_NODEV" "$IMAGE_FILE"
                  retval=$?
                  ;;
      partclone)  $GZIP -d -c "$IMAGE_FILE" |partclone.restore -s - -o "/dev/$TARGET_PART_NODEV"
                  retval=$?
                  if [ ${PIPESTATUS[0]} -ne 0 ]; then
                    retval=1
                  fi
                  ;;
      ddgz)       $GZIP -d -c "$IMAGE_FILE" |dd of="/dev/$TARGET_PART_NODEV" bs=4096
                  retval=$?
                  if [ ${PIPESTATUS[0]} -ne 0 ]; then
                    retval=1
                  fi
                  ;;
    esac

    if [ $retval -ne 0 ]; then
      FAILED="${FAILED}${FAILED:+ }${TARGET_PART_NODEV}"
      printf "\033[40m\033[1;31mWARNING: Error($retval) occurred during image restore for $IMAGE_FILE on /dev/$TARGET_PART_NODEV.\nPress <enter> to continue or CTRL-C to abort...\n\033[0m" >&2
      read dummy
    else
      SUCCESS="${SUCCESS}${SUCCESS:+ }${TARGET_PART_NODEV}"
      echo "****** $IMAGE_FILE restored to /dev/$TARGET_PART_NODEV ******"
    fi
    echo ""
  done
}


restore_disks()
{
  # Restore MBR/track0/partitions
  TARGET_NODEV=""
  unset IFS
  for FN in partitions.*; do
    HDD_NAME="$(basename "$FN" |sed s/'.*\.'//)"

    # If no target drive specified use default drive from image:
    if [ -n "$USER_TARGET_NODEV" ]; then
      TARGET_NODEV="$USER_TARGET_NODEV"
    else
      if [ -z "$TARGET_NODEV" ]; then
        # Extract drive name from file
        TARGET_NODEV="$HDD_NAME"
      fi
    fi

    # Check if target device exists
    if ! get_partitions |grep -q -x "$TARGET_NODEV"; then
      echo ""
      printf "\033[40m\033[1;31mERROR: Target device /dev/$TARGET_NODEV does NOT exist! Quitting...\n\033[0m" >&2
      echo ""
      do_exit 5
    fi

    # Check if DMA is enabled for device
    check_dma "/dev/$TARGET_NODEV"

    # Check whether device already contains partitions
    PARTITIONS_FOUND=`get_partitions |grep -E -x "${TARGET_NODEV}p?[0-9]+"`

    if [ $CLEAN -eq 1 ]; then
      CHECK_PARTITIONS="$PARTITIONS_FOUND"
    else
      CHECK_PARTITIONS="$PARTITIONS_NODEV"
    fi

    IFS=$EOL
    for PART in $CHECK_PARTITIONS; do
      # (Try) to unmount partitions on target device
      if grep -E -q "^/dev/${PART}[[:blank:]]" /etc/mtab; then
        if ! umount /dev/$PART >/dev/null; then
          echo ""
          printf "\033[40m\033[1;31mERROR: Unable to umount /dev/$PART. Wrong target device specified? Quitting...\n\033[0m" >&2
          echo ""
          do_exit 5
        fi
      fi

      # Disable all swaps on this device
      if grep -E -q "^/dev/${PART}[[:blank:]]" /proc/swaps; then
        if ! swapoff /dev/$PART >/dev/null; then
          echo ""
          printf "\033[40m\033[1;31mERROR: Unable to swapoff /dev/$PART. Wrong target device specified? Quitting...\n\033[0m" >&2
          echo ""
          do_exit 5
        fi
      fi
    done
    
    # Flag in case we update the mbr/partition table so we know we need to have the kernel to re-probe
    PARTPROBE=0

    # Check for MBR restore
    if [ $CLEAN -eq 1 -o $MBR_WRITE -eq 1 ]; then
      if [ -f "track0.${HDD_NAME}" ]; then
        DD_SOURCE="track0.${HDD_NAME}"
      else
        echo "WARNING: No track0.${HDD_NAME} found. MBR will be zeroed instead!" >&2
        DD_SOURCE="/dev/zero"
      fi

      echo "* Updating track0(MBR) on /dev/$TARGET_NODEV from $DD_SOURCE"
      
      if [ $CLEAN -eq 1 -o -z "$PARTITIONS_FOUND" ]; then
        result=`dd if="$DD_SOURCE" of=/dev/$TARGET_NODEV bs=32768 count=1 2>&1`
        retval=$?
      else
        result=`dd if="$DD_SOURCE" of=/dev/$TARGET_NODEV bs=446 count=1 2>&1 && dd if="$DD_SOURCE" of=/dev/$TARGET_NODEV seek=512 skip=512 bs=1 count=32256 2>&1`
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
    
    echo ""
    
    # Check for partition restore
    if [ -n "$PARTITIONS_FOUND" -a $CLEAN -eq 0 -a $PT_WRITE -eq 0 ]; then
      printf "\033[40m\033[1;31mWARNING: Target device /dev/$TARGET_NODEV already contains a partition table, it will NOT be updated!\n\033[0m" >&2
      echo "To override this you must specify --clean or --pt. Press <enter> to continue or CTRL-C to abort..." >&2
      read dummy
      echo ""
    else
      if [ -f "partitions.$HDD_NAME" ]; then
        echo "* Updating partition table on /dev/$TARGET_NODEV"
        sfdisk --force --no-reread /dev/$TARGET_NODEV < "partitions.$HDD_NAME"
        retval=$?
          
        if [ $retval -ne 0 ]; then
          printf "\033[40m\033[1;31mPartition table restore failed($retval). Quitting...\n\033[0m" >&2
          do_exit 5
        fi
        PARTPROBE=1
        echo ""
      fi
    fi
    
    if [ $PARTPROBE -eq 1 ]; then
      # Re-read partition table
      partprobe "/dev/$TARGET_NODEV"
      retval=$?
      if [ $retval -ne 0 ]; then
        printf "\033[40m\033[1;31mWARNING: (Re)reading the partition table failed($retval)!\nPress <enter> to continue or CTRL-C to abort...\n\033[0m" >&2
        read dummy
        echo ""
      fi
    fi
    
    if [ $CLEAN -eq 1 ]; then
      # Create swap on swap partitions
      IFS=$EOL
      sfdisk -d /dev/$TARGET_NODEV 2>/dev/null |grep -i "id=82$" |while read LINE; do
        PART="$(echo "$LINE" |awk '{ print $1 }')"
        if ! mkswap $PART; then
          printf "\033[40m\033[1;31mWARNING: mkswap failed for $PART\n\033[0m" >&2
        fi
      done
    fi
  done
}


verify_target()
{
  # Test whether the target partition(s) exist and have the correct geometry:
  local MISMATCH=0
  unset IFS
  for IMAGE_FILE in $IMAGE_FILES; do
    # Strip extension so we get the actual device name
    PARTITION="$(echo "$IMAGE_FILE" |sed 's/\..*//')"
    
    # Do we want another target device than specified in the image name?:
    if [ -n "$USER_TARGET_NODEV" ]; then
      NUM="$(echo "$PARTITION" |sed -e 's,^[a-z]*,,' -e 's,^.*p,,')"
      SFDISK_TARGET_PART=`sfdisk -d 2>/dev/null |grep -E "^/dev/${USER_TARGET_NODEV}p?${NUM}[[:blank:]]"`
      if [ -z "$SFDISK_TARGET_PART" ]; then
        printf "\033[40m\033[1;31m\nERROR: Target partition $NUM on /dev/$USER_TARGET_NODEV does NOT exist! Quitting...\n\033[0m" >&2
        do_exit 5
      fi
    else
      SFDISK_TARGET_PART=`sfdisk -d 2>/dev/null |grep -E "^/dev/${PARTITION}[[:blank:]]"`
      if [ -z "$SFDISK_TARGET_PART" ]; then
        printf "\033[40m\033[1;31m\nERROR: Target partition /dev/$PARTITION does NOT exist! Quitting...\n\033[0m" >&2
        do_exit 5
      fi
    fi

    ## Match partition with what we have stored in our partitions file
    SFDISK_SOURCE_PART=`cat partitions.* |grep -E "^/dev/${PARTITION}[[:blank:]]"`
    if [ -z "$SFDISK_SOURCE_PART" ]; then
      printf "\033[40m\033[1;31m\nERROR: Partition /dev/$PARTITION can not be found in the partitions.* files! Quitting...\n\033[0m" >&2
      do_exit 5
    fi

    echo "* Source partition: $SFDISK_SOURCE_PART"
    echo "* Target partition: $SFDISK_TARGET_PART"
    echo ""

    if ! echo "$SFDISK_TARGET_PART" |grep -q "$(echo "$SFDISK_SOURCE_PART" |sed s,"^/dev/${PARTITION}[[:blank:]]","",)"; then
      MISMATCH=1
    fi
  done

  if [ $MISMATCH -ne 0 ]; then
    printf "\033[40m\033[1;31mWARNING: Target partition mismatches with source! Press <enter> to continue or CTRL-C to quit...\n\033[0m" >&2
    read dummy
    echo ""
    return 1
  fi
  
  return 0
}


check_image_files()
{
  IMAGE_FILES=""
  if [ -n "$PARTITIONS_NODEV" ]; then
    IFS=' '
    for PART in $PARTITIONS_NODEV; do
      IFS=$EOL
      ITEM="$(find . -maxdepth 1 -type f -iname "$PART.img.gz.000" -o -iname "$PART.fsa" -o -iname "$PART.dd.gz" -o -iname "$PART.pc.gz")"

      if [ -z "$ITEM" ]; then
        printf "\033[40m\033[1;31m\nERROR: Image file for partition /dev/$PART could not be located! Quitting...\n\033[0m" >&2
        do_exit 5
      fi

      if [ $(echo "$ITEM" |wc -l) -gt 1 ]; then
        echo "$ITEM"
        printf "\033[40m\033[1;31m\nERROR: Found multiple image files for partition /dev/$PART! Quitting...\n\033[0m" >&2
        do_exit 5
      fi

      IMAGE_FILE=`basename "$ITEM"`

      IMAGE_FILES="${IMAGE_FILES}${IMAGE_FILES:+ }${IMAGE_FILE}"

      echo "* Using image file \"${ITEM}\" for device /dev/$PART"
    done
  else
    IFS=$EOL
    for ITEM in `find . -maxdepth 1 -type f -iname "*.img.gz.000" -o -iname "*.fsa" -o -iname "*.dd.gz" -o -iname "*.pc.gz"`; do
      IMAGE_FILE=`basename "$ITEM"`
      # Add item to list
      IMAGE_FILES="${IMAGE_FILES}${IMAGE_FILES:+ }${IMAGE_FILE}"

      PART="$(echo "$IMAGE_FILE" |sed 's/\..*//')"
      echo "* Using image file \"${IMAGE_FILE}\" for device /dev/$PART"
    done
  fi

  if [ -z "$IMAGE_FILES" ]; then
    printf "\033[40m\033[1;31m\nERROR: No matching image files found to restore! Quitting...\n\033[0m" >&2
    do_exit 5
  fi

  # Make sure the proper binaries are available
  IFS=' '
  for IMAGE_FILE in $IMAGE_FILES; do
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


show_help()
{
  echo "Usage: restore-image.sh [options] [image-name]"
  echo ""
  echo "Options:"
  echo "--help|-h                   - Print this help"
  echo "--part|-p={dev1,dev2}       - Restore only these partitions (instead of all partitions)"
  echo "--conf|-c={config_file}     - Specify alternate configuration file"
  echo "--noconf                    - Don't read the config file"
  echo "--mbr                       - Always write a new MBR (from track0.*)"
  echo "--pt                        - Always write a new partition table (from partition.*)"
  echo "--clean                     - Always write MBR/partition table/swap space even if device is not empty (USE WITH CARE!)"
  echo "--dev|-d={dev}              - Restore image to target device {dev} (instead of default)"
  echo "--nonet|-n                  - Don't try to setup networking"
  echo "--nomount|-m                - Don't mount anything"
  echo "--nopostsh|--nosh           - Don't execute any post image shell scripts"
}


load_config()
{
  # Set environment variables to default
  CONF="$DEFAULT_CONF"
  IMAGE_NAME=""
  SUCCESS=""
  FAILED=""
  USER_TARGET_NODEV=""
  PARTITIONS_NODEV=""
  CLEAN=0
  NO_NET=0
  NO_CONF=0
  MBR_WRITE=0
  PT_WRITE=0
  NO_POST_SH=0
  NO_MOUNT=0

  # Check arguments
  unset IFS
  for arg in $*; do
    ARGNAME=`echo "$arg" |cut -d= -f1`
    ARGVAL=`echo "$arg" |cut -d= -f2`

    case "$ARGNAME" in
      --clean|-c) CLEAN=1;;
      --dev|-d) USER_TARGET_NODEV=`echo "$ARGVAL" |sed 's|^/dev/||g'`;;
      --partitions|--partition|--part|-p) PARTITIONS_NODEV=`echo "$ARGVAL" |sed -e 's|,| |g' -e 's|^/dev/||g'`;;
      --conf|-c) CONF="$ARGVAL";;
      --nonet|-n) NO_NET=1;;
      --nomount|-m) NO_MOUNT=1;;
      --noconf) NO_CONF=1;;
      --mbr) MBR_WRITE=1;;
      --pt) PT_WRITE=1;;
      --nopostsh|--nosh) NO_POST_SH=1;;
      --help|-h) show_help; exit 3;;
      -*) echo "Bad argument: $ARGNAME"; show_help; exit 4;;
      *) IMAGE_NAME="$ARGVAL"
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

# Check if target device exists
if [ -n "$USER_TARGET_NODEV" ]; then
  if ! get_partitions |grep -q -x "$USER_TARGET_NODEV"; then
    echo ""
    printf "\033[40m\033[1;31mERROR: Specified target device $USER_TARGET_NODEV does NOT exist! Quitting...\n\033[0m" >&2
    echo ""
    exit 5
  fi
fi

if [ "$NETWORK" != "none" -a -n "$NETWORK" -a "$NO_NET" != "1" ]; then
  # Setup network (interface)
  configure_network;

  # Try to sync time against the server used, if ntpdate is available
  if which ntpdate >/dev/null 2>&1 && [ -n "$SERVER" ]; then
    ntpdate "$SERVER"
  fi
fi

# Setup CTRL-C handler
trap 'ctrlc_handler' 2

set_image_dir;

echo "--------------------------------------------------------------------------------"
echo "* Using image name: $IMAGE_DIR"
echo "* Image working directory: $(pwd)"

# Make sure we're in the correct working directory:
if ! pwd |grep -q "$IMAGE_DIR$"; then
  printf "\033[40m\033[1;31mERROR: Unable to access image directory ($IMAGE_DIR)!\n\033[0m" >&2
  do_exit 7
fi

check_image_files;

if [ -e "description.txt" ]; then
  echo "--------------------------------------------------------------------------------"
  cat "description.txt"
fi

echo "--------------------------------------------------------------------------------"
echo "Press <enter> to continue"
read dummy
echo ""

# Restore MBR/partition tables + setup swap
restore_disks;

# Make sure the target is sane
verify_target;
 
# Restore images to partitions
restore_partitions;

# Reset terminal
#reset

# Set this for legacy scripts:
TARGET_DEVICE="$TARGET_NODEV"

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

echo ""

# Show current partition status
for FN in partitions.*; do
  HDD_NAME="$(basename "$FN" |sed s/'.*\.'//)"
  fdisk -l "/dev/$HDD_NAME" |grep "^/"
done

if [ -n "$FAILED" ]; then
  echo "* Partitions restored with errors: $FAILED"
fi

echo "* Partitions restored successfully: $SUCCESS"

# Exit (+unmount)
do_exit 0
