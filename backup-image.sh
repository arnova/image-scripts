#!/bin/bash

MY_VERSION="3.10-BETA16-GPT-DEVEL"
# ----------------------------------------------------------------------------------------------------------------------
# Image Backup Script with (SMB) network support
# Last update: October 29, 2013
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

##################
# Define globals #
##################
BACKUP_IMAGES=""
BACKUP_PARTITIONS=""
IGNORE_PARTITIONS=""
BACKUP_DISKS=""
SUCCESS=""
FAILED=""

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


# $1 = disk device to get partitions from, if not specified all available partitions are listed
get_partitions_with_size_type()
{
  local DISK_NODEV=`echo "$1" |sed s,'^/dev/',,`

  IFS=$EOL
  get_partitions_with_size "$DISK_NODEV" |while read LINE; do
    local PART_NODEV=`echo "$LINE" |awk '{ print $1 }'`
    local TYPE=`blkid -s TYPE -o value "/dev/${PART_NODEV}"`

    if [ -z "$TYPE" ]; then
      TYPE="other" # = eg. extended partition, disk device, sr0, loop0 etc.
    fi
    echo "$LINE $TYPE"
  done
}


# $1 = disk device to get partitions from, if not specified all available partitions are listed
get_partitions_fancified()
{
  local DISK_NODEV=`echo "$1" |sed s,'^/dev/',,`

  IFS=$EOL
  get_partitions_with_size "$DISK_NODEV" |while read LINE; do
    local PART_NODEV=`echo "$LINE" |awk '{ print $1 }'`
    local BLKINFO="$(blkid "/dev/$PART_NODEV" |sed s/' *$'//)"
    local SIZE=`echo "$LINE" |awk '{ print $2 }'`

    GB_SIZE=$(($SIZE / 1024 / 1024))
    if [ $GB_SIZE -eq 0 ]; then
      MB_SIZE=$(($SIZE / 1024))
      SIZE_HUMAN="${MB_SIZE} MiB"
    else
      SIZE_HUMAN="${GB_SIZE} GiB"
    fi

    if [ -z "$BLKINFO" ]; then
      BLKINFO="/dev/${PART_NODEV}: TYPE=\"other\""
    fi

    echo "$BLKINFO SIZE=$SIZE SIZEH=$SIZE_HUMAN"
  done
}


# Figure out to which disk the specified partition ($1) belongs
get_partition_disk()
{
  echo "$1" |sed -r s,'p?[0-9]+$',,
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
    GB_SIZE=$(($SIZE / 2 / 1024 / 1024))
    if [ $GB_SIZE -eq 0 ]; then
      MB_SIZE=$(($SIZE / 2 / 1024))
      printf "\t${MB_SIZE} MiB"
    else
      printf "\t${GB_SIZE} GiB"
    fi
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


# Wrapper for partclone to autodetect filesystem and select the proper partclone.*
partclone_detect()
{
  local PART="$1"
  local PARTCLONE_BIN=""

  local TYPE=`blkid -s TYPE -o value "$PART"` # May try `file -s -b "$PART"` instead but blkid seems to work better
  case $TYPE in
    ntfs)                           PARTCLONE_BIN="partclone.ntfs"
                                    ;;
    vfat|msdos|fat*)                PARTCLONE_BIN="partclone.fat"
                                    ;;
    ext2|ext3|ext4)                 PARTCLONE_BIN="partclone.extfs"
                                    ;;
    btrfs)                          PARTCLONE_BIN="partclone.btrfs"
                                    ;;
    *)                              PARTCLONE_BIN="partclone.dd"
                                    ;;
  esac

  check_command_error "$PARTCLONE_BIN"

  echo "$PARTCLONE_BIN"
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
  check_command_error gzip
  check_command_error sfdisk
  check_command_error fdisk
  check_command_error dd
  check_command_error blkid

  check_command_warning sgdisk
  check_command_warning gdisk

  [ "$NO_NET" != "0" ] && check_command_error ifconfig
  [ "$NO_MOUNT" != "0" ] && check_command_error mount
  [ "$NO_MOUNT" != "0" ] && check_command_error umount

  [ "$IMAGE_PROGRAM" = "fsa" ] && check_command_error fsarchiver
  [ "$IMAGE_PROGRAM" = "pi" ] && check_command_error partimage
  
  if [ "$IMAGE_PROGRAM" = "pc" -o "$IMAGE_PROGRAM" = "ddgz" ]; then
    GZIP="gzip"
  fi

  if [ "$IMAGE_PROGRAM" = "pc" ]; then
    # This is a dummy test for partclone, the actual binary test is in the wrapper
    check_command_error partclone.restore 
  fi
}


# mkdir + sanity check (cd) access to it
mkdir_safe()
{
  local IMAGE_DIR="$1"

  if ! mkdir -p "$IMAGE_DIR"; then
    echo ""
    printf "\033[40m\033[1;31mERROR: Unable to create target image directory ($IMAGE_DIR)!\n\033[0m" >&2
    return 1
  fi

  if [ ! -d "$IMAGE_DIR" ]; then
    printf "\033[40m\033[1;31m\nERROR: Image target directory $IMAGE_DIR does NOT exist!\n\033[0m" >&2
    return 2
  fi

  # Make the image dir our working directory
  if ! cd "$IMAGE_DIR"; then
    printf "\033[40m\033[1;31m\nERROR: Unable to cd to image directory $IMAGE_DIR!\n\033[0m" >&2
    return 3
  fi
  
  return 0
}


set_image_target_dir()
{
  if echo "$IMAGE_NAME" |grep -q '^[\./]' || [ $NO_MOUNT -eq 1 ]; then
    # Assume absolute path
    IMAGE_DIR="$IMAGE_NAME"
    
    if ! mkdir_safe "$IMAGE_DIR"; then
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

    if [ -z "$IMAGE_NAME" ]; then
      while true; do
        printf "\nImage name (directory) to use: "
        read IMAGE_NAME
        
        if [ -z "$IMAGE_NAME" ]; then
          echo ""
          printf "\033[40m\033[1;31mERROR: You must specify the image target directory to be used!\n\033[0m" >&2
          continue;
        fi
      
        IMAGE_DIR="$IMAGE_NAME"
    
        if [ -n "$IMAGE_BACKUP_DIR" ]; then
          IMAGE_DIR="${IMAGE_BACKUP_DIR}/${IMAGE_DIR}"
        fi

        if [ -n "$IMAGE_ROOT" ]; then
          IMAGE_DIR="$IMAGE_ROOT/$IMAGE_DIR"
        fi

        if ! mkdir_safe "$IMAGE_DIR"; then
          continue;
        fi
    
        echo ""
        break; # All sane: break loop
      done
    else
      IMAGE_DIR="$IMAGE_NAME"
    
      if [ -n "$IMAGE_BACKUP_DIR" ]; then
        IMAGE_DIR="${IMAGE_BACKUP_DIR}/${IMAGE_DIR}"
      fi

      if [ -n "$IMAGE_ROOT" ]; then
        IMAGE_DIR="$IMAGE_ROOT/$IMAGE_DIR"
      fi
      
      if ! mkdir_safe "$IMAGE_DIR"; then
        do_exit 7;
      fi
    fi
  fi
}


select_disks()
{
  BACKUP_DISKS=""

  IFS=' '
  for PART in $BACKUP_PARTITIONS; do
    local HDD_NODEV=`get_partition_disk "$PART"`
    if ! echo "$BACKUP_DISKS" |grep -q -e "^${HDD_NODEV}$" -e "^${HDD_NODEV} " -e " ${HDD_NODEV}$" -e " ${HDD_NODEV} "; then
      BACKUP_DISKS="${BACKUP_DISKS}${BACKUP_DISKS:+ }${HDD_NODEV}"
    fi
  done
}


show_backup_disks_info()
{
  IFS=' '
  for HDD in $BACKUP_DISKS; do
    HDD_NODEV=`get_partition_disk "$HDD"`
    echo "* Available backup disk /dev/$HDD_NODEV: $(show_block_device_info $HDD_NODEV)"
    get_partitions_fancified /dev/$HDD_NODEV
    echo ""
  done
}


select_partitions()
{
  local SELECT_DEVICES="$DEVICES"
  local LAST_BACKUP_DISKS=""
  local USER_SELECT=0
 
  # User select loop:
  while true; do
    # Check if target device exists
    if [ -n "$SELECT_DEVICES" ]; then
      local SELECT_PARTITIONS=""
      BACKUP_PARTITIONS=""
      IGNORE_PARTITIONS=""

      unset IFS
      for DEVICE in $SELECT_DEVICES; do
        if [ ! -e "/dev/$DEVICE" ]; then
          echo ""
          printf "\033[40m\033[1;31mERROR: Specified source block device /dev/$DEVICE does NOT exist! Quitting...\n\033[0m" >&2
          echo ""
          exit 5
        else
          local FIND_PARTITIONS="$(get_partitions_with_size_type /dev/$DEVICE)"
          # Does the device contain partitions?
          if [ -n "$FIND_PARTITIONS" ]; then
            local FILTER_PARTITIONS="$(echo "$FIND_PARTITIONS" |grep -v -e ' swap$' -e ' other$' -e ' unknown$' -e ' squashfs$' |awk '{ printf ("%s ",$1) }')"
            SELECT_PARTITIONS="${SELECT_PARTITIONS}${SELECT_PARTITIONS:+ }${FILTER_PARTITIONS}"
          else
            SELECT_PARTITIONS="${SELECT_PARTITIONS}${SELECT_PARTITIONS:+ }${DEVICE}"
          fi
        fi
      done
    else
      USER_SELECT=1

      # If no argument(s) given, "detect" all partitions (but ignore swap & extended partitions, etc.)
      SELECT_PARTITIONS="$(get_partitions_with_size_type |grep -v -e ' swap$' -e ' other$' -e ' unknown$'  -e ' squashfs$' |awk '{ printf ("%s ",$1) }')"
    fi

    # Check which partitions to backup, we ignore mounted ones
    unset IFS
    for PART_NODEV in $SELECT_PARTITIONS; do
      if grep -E -q "^/dev/${PART_NODEV}[[:blank:]]" /etc/mtab; then
        # In case user specifically selected partition, hardfail:
        if echo "$DEVICES" |grep -q -e "^${PART_NODEV}$" -e "^${PART_NODEV} " -e " ${PART_NODEV}$" -e " ${PART_NODEV} "; then
          printf "\033[40m\033[1;31mERROR: Partition /dev/$PART_NODEV is mounted! Wrong device/partition specified? Quitting...\n\033[0m" >&2
          do_exit 5
        fi

        IGNORE_PARTITIONS="${IGNORE_PARTITIONS}${IGNORE_PARTITIONS:+ }${PART_NODEV}"
      elif grep -E -q "^/dev/${PART_NODEV}[[:blank:]]" /proc/swaps; then
        # In case user specifically selected partition, hardfail:
        if echo "$DEVICES" |grep -q -e "^${PART_NODEV}$" -e "^${PART_NODEV} " -e " ${PART_NODEV}$" -e " ${PART_NODEV} "; then
          printf "\033[40m\033[1;31mERROR: Partition /dev/$PART_NODEV is used as swap! Wrong device/partition specified? Quitting...\n\033[0m" >&2
          do_exit 5
        fi

        IGNORE_PARTITIONS="${IGNORE_PARTITIONS}${IGNORE_PARTITIONS:+ }${PART_NODEV}"
      else
        BACKUP_PARTITIONS="${BACKUP_PARTITIONS}${BACKUP_PARTITIONS:+ }${PART_NODEV}"
      fi
    done

    if [ -n "$BACKUP_PARTITIONS" ]; then
      select_disks; # Determine which disks the partitions are on

      # Only show info when not shown before
      if [ "$BACKUP_DISKS" != "$LAST_BACKUP_DISKS" ]; then
        if [ -n "IGNORE_PARTITIONS" ]; then
          echo "NOTE: Ignored (mounted/swap) partitions: $IGNORE_PARTITIONS"
        fi

        show_backup_disks_info;

        LAST_BACKUP_DISKS="$BACKUP_DISKS"
      fi

      if [ $USER_SELECT -eq 1 ]; then
        printf "* Select partitions to backup (default=$BACKUP_PARTITIONS): "
        read USER_DEVICES

        IGNORE_PARTITIONS="" # Don't confuse user by showing ignored partitions

        if [ -z "$USER_DEVICES" ]; then
          break;
        else
          SELECT_DEVICES="$USER_DEVICES"
          USER_SELECT=0
          continue; # Redo loop
        fi
       else
         break;
      fi
    else
      echo "ERROR: No partitions to backup on $SELECT_DEVICES"
      echo ""
      SELECT_DEVICES=""
      USER_SELECT=1
    fi
  done
}


backup_partitions()
{
  # Backup all specified partitions:
  unset IFS
  for PART in $BACKUP_PARTITIONS; do
    local retval=1
    case "$IMAGE_PROGRAM" in
      fsa)  TARGET_FILE="$PART.fsa"
            printf "****** Using fsarchiver to backup /dev/$PART to $TARGET_FILE ******\n\n"
            fsarchiver -v savefs "$TARGET_FILE" "/dev/$PART"
            retval=$?
            ;;
      pi)   TARGET_FILE="$PART.img.gz"
            printf "****** Using partimage to backup /dev/$PART to $TARGET_FILE ******\n\n"
            partimage -z1 -b -d save "/dev/$PART" "$TARGET_FILE"
            retval=$?
            if [ $retval -eq 0 ]; then
              BACKUP_IMAGES="${BACKUP_IMAGES}${TARGET_FILE} "
            fi
            ;;
      pc)   TARGET_FILE="$PART.pc.gz"
            PARTCLONE=`partclone_detect "/dev/$PART"`
            if [ -n "$PARTCLONE" ]; then
              printf "****** Using $PARTCLONE (+${GZIP} -${GZIP_COMPRESSION}) to backup /dev/$PART to $TARGET_FILE ******\n\n"
              { $PARTCLONE -c -s "/dev/$PART"; echo $? >/tmp/.partclone.exitcode; } |$GZIP -$GZIP_COMPRESSION -c >"$TARGET_FILE"
              retval=$?
              if [ $retval -eq 0 ]; then
                retval=`cat /tmp/.partclone.exitcode`
                if [ $retval -eq 0 ]; then
                  BACKUP_IMAGES="${BACKUP_IMAGES}${TARGET_FILE} "
                fi
              fi
            fi
            ;;
      ddgz) TARGET_FILE="$PART.dd.gz"
            printf "****** Using dd (+${GZIP} -${GZIP_COMPRESSION}) to backup /dev/$PART to $TARGET_FILE ******\n\n"
            { dd if="/dev/$PART" bs=4096; echo $? >/tmp/.dd.exitcode; } |$GZIP -$GZIP_COMPRESSION -c >"$TARGET_FILE"
            retval=$?
            if [ $retval -eq 0 ]; then
              retval=`cat /tmp/.dd.exitcode`
              if [ $retval -eq 0 ]; then
                BACKUP_IMAGES="${BACKUP_IMAGES}${TARGET_FILE} "
              fi
            fi
            ;;
    esac

    echo ""
    if [ $retval -ne 0 ]; then
      FAILED="${FAILED}${FAILED:+ }$PART"
      printf "\033[40m\033[1;31mERROR: Image backup failed($retval) for $TARGET_FILE from /dev/$PART.\nPress <enter> to continue or CTRL-C to abort...\n\033[0m" >&2
      read dummy
    else
      SUCCESS="${SUCCESS}${SUCCESS:+ }$PART"
      echo "****** Backuped /dev/$PART to $TARGET_FILE ******"
    fi
    echo ""
  done
}


backup_disks()
{
  # Backup all disks
  local HDD_NODEV=""
  IFS=' '
  for HDD_NODEV in $BACKUP_DISKS; do
    # Check if DMA is enabled for HDD
    check_dma /dev/$HDD_NODEV

    echo "* Storing track0 for /dev/$HDD_NODEV in track0.$HDD_NODEV..."
    # Dump hdd info for all disks in the current system
    result=`dd if=/dev/$HDD_NODEV of="track0.$HDD_NODEV" bs=512 count=2048 2>&1` # NOTE: Dump 1MiB instead of 63*512 (track0) = 32256 bytes due to Grub2 using more on disks with partition one starting at cylinder 2048 (4KB disks)
    retval=$?
    if [ $retval -ne 0 ]; then
      echo "$result" >&2
      printf "\033[40m\033[1;31mERROR: Track0(MBR) backup from /dev/$HDD_NODEV failed($retval)! Quitting...\n\033[0m" >&2
      do_exit 8
    fi

    SFDISK_OUTPUT=`sfdisk -d "/dev/${HDD_NODEV}" 2>/dev/null`
    if echo "$SFDISK_OUTPUT" |grep -q -E -i '^/dev/.*[[:blank:]]Id=ee'; then
      # GPT partition table found
      echo "* Storing GPT partition table for /dev/$HDD_NODEV in sgdisk.$HDD_NODEV..."
      sgdisk --backup="sgdisk.${HDD_NODEV}" "/dev/${HDD_NODEV}"

      # Dump gdisk -l info to file
      gdisk -l "/dev/${HDD_NODEV}" >"gdisk.${HDD_NODEV}"
    elif [ -n "$SFDISK_OUTPUT" ]; then
      # DOS partition table found
      echo "* Storing DOS partition table for /dev/$HDD_NODEV in sfdisk.$HDD_NODEV..."
      echo "$SFDISK_OUTPUT" > "sfdisk.$HDD_NODEV"

      # Dump fdisk -l info to file
      fdisk -l "/dev/${HDD_NODEV}" >"fdisk.${HDD_NODEV}"
    else
      printf "\033[40m\033[1;31mERROR: Unable to obtain GPT or DOS partition table for /dev/$HDD_NODEV! Quitting...\n\033[0m" >&2
      do_exit 9
    fi

    # Dump device partition layout in "fancified" format
    get_partitions_fancified "$HDD_NODEV" >"partition_layout.${HDD_NODEV}"
  done
}


show_help()
{
  echo "Usage: backup-image.sh [options] [image-name]" >&2
  echo "" >&2
  echo "Options:" >&2
  echo "--help|-h                   - Print this help" >&2
  echo "--dev|-d={dev1,dev2}        - Backup only these devices/partitions (instead of all)" >&2
  echo "--conf|-c={config_file}     - Specify alternate configuration file" >&2
  echo "--compression|-z=level      - Set gzip compression level (when used). 1=Low but fast (default), 9=High but slow" >&2
  echo "--notrack0                  - Don't backup any track0(MBR)/partition-tables" >&2
  echo "--noconf                    - Don't read the config file" >&2
  echo "--fsa                       - Use fsarchiver for imaging" >&2
  echo "--pi                        - Use partimage for imaging" >&2
  echo "--pc                        - Use partclone + gzip for imaging" >&2
  echo "--ddgz                      - Use dd + gzip for imaging" >&2
  echo "--nonet|-n                  - Don't try to setup networking" >&2
  echo "--nomount|-m                - Don't mount anything" >&2
  echo "--noimage                   - Don't create any partition images, only do partition-table/MBR operations" >&2
  echo "--noccustomsh|--nosh        - Don't execute any custom shell script(s)" >&2
  echo "--onlysh|--sh               - Only execute user (shell) script(s)" >&2
}


load_config()
{
  # Set environment variables to default
  CONF="$DEFAULT_CONF"
  IMAGE_NAME=""
  DEVICES=""
  IMAGE_PROGRAM=""
  NO_NET=0
  NO_CONF=0
  GZIP_COMPRESSION=1
  NO_MOUNT=0
  NO_TRACK0=0
  NO_CUSTOM_SH=0
  NO_IMAGE=0
  ONLY_SH=0

  # Check arguments
  unset IFS
  for arg in $*; do
    ARGNAME=`echo "$arg" |cut -d= -f1`
    ARGVAL=`echo "$arg" |cut -d= -f2 -s`

    case "$ARGNAME" in
      --part|--partitions|-p|--dev|--devices|-d) DEVICES=`echo "$ARGVAL" |sed -e 's|,| |g' -e 's|^/dev/||g'`;; # Make list space seperated and remove /dev/ prefixes
                                     --notrack0) NO_TRACK0=1;;
                               --compression|-z) GZIP_COMPRESSION="$ARGVAL";;
                                      --conf|-c) CONF="$ARGVAL";;
                                          --fsa) IMAGE_PROGRAM="fsa";;
                                         --ddgz) IMAGE_PROGRAM="ddgz";;
                                           --pi) IMAGE_PROGRAM="pi";;
                                           --pc) IMAGE_PROGRAM="pc";;
                                     --nonet|-n) NO_NET=1;;
                                   --nomount|-m) NO_MOUNT=1;;
                                       --noconf) NO_CONF=1;;
                            --nocustomsh|--nosh) NO_CUSTOM_SH=1;;
                               --noimage|--noim) NO_IMAGE=1;;
                                  --onlysh|--sh) ONLY_SH=1;;
                                      --help|-h) show_help;
                                                 exit 0
                                                 ;;
                                             -*) echo "ERROR: Bad argument \"$arg\"" >&2
                                                 show_help;
                                                 exit 4
                                                 ;;
                                              *) if [ -z "$IMAGE_NAME" ]; then
                                                   IMAGE_NAME="$arg"
                                                 else
                                                   echo "ERROR: Bad command syntax with argument \"$arg\"" >&2
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

  if [ -z "$IMAGE_PROGRAM" ]; then
    if [ -n "$DEFAULT_IMAGE_PROGRAM" ]; then
      IMAGE_PROGRAM="$DEFAULT_IMAGE_PROGRAM"
    else
      IMAGE_PROGRAM="pc"
    fi
  fi

  # Sanity check compression
  if [ -z "$GZIP_COMPRESSION" -o $GZIP_COMPRESSION -lt 1 -o $GZIP_COMPRESSION -gt 9 ]; then
    GZIP_COMPRESSION=1
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
echo "Image BACKUP Script v$MY_VERSION - Written by Arno van Amersfoort"

# Load configuration from file/commandline
load_config $*;

# Sanity check environment
sanity_check;

if [ "$NETWORK" != "none" -a -n "$NETWORK" -a $NO_NET -ne 1 ]; then
  # Setup network (interface)
  configure_network;

  # Try to sync time against the server used, if ntpdate is available
  if which ntpdate >/dev/null 2>&1 && [ -n "$SERVER" ]; then
    ntpdate "$SERVER"
  fi
fi

# Setup CTRL-C handler
trap 'ctrlc_handler' 2

set_image_target_dir;

echo "--------------------------------------------------------------------------------"
echo "* Using image name: $IMAGE_DIR"
echo "* Image working directory: $(pwd)"

# Make sure we're in the correct working directory:
if ! pwd |grep -q "$IMAGE_DIR$"; then
  printf "\033[40m\033[1;31mERROR: Unable to access image directory ($IMAGE_DIR)!\n\033[0m" >&2
  do_exit 7
fi

# Make sure target directory is empty
if [ -n "$(find . -maxdepth 1 -type f)" ]; then
  echo ""
  find . -maxdepth 1 -type f -exec ls -l {} \;
  if get_user_yn "Image target directory is NOT empty. PURGE directory before continueing (Y/N) (CTRL-C to abort)?"; then
    find . -maxdepth 1 -type f -exec rm -vf {} \;
  fi
  echo ""
fi

# Determine which partitions to backup, else determines disks they're on
select_partitions;

if [ $NO_IMAGE -eq 0 -a $ONLY_SH -eq 0 ]; then
  if [ -n "$BACKUP_PARTITIONS" ]; then
    echo "* Partitions to backup: $BACKUP_PARTITIONS"
  else
    echo "* Partitions to backup: none"
  fi

  if [ -z "$BACKUP_PARTITIONS" ]; then
    printf "\033[40m\033[1;31mWARNING: No partitions to backup!?\nPress <enter> to continue or CTRL-C to abort...\n\033[0m" >&2
    read dummy
  fi
fi

if [ $NO_TRACK0 -ne 1 -a $ONLY_SH -eq 0 ]; then
  if [ -z "$BACKUP_DISKS" ]; then
    printf "\033[40m\033[1;31mWARNING: No disks to backup!?\nPress <enter> to continue or CTRL-C to abort...\n\033[0m" >&2
    read dummy
  fi
fi

echo ""

if [ $ONLY_SH -eq 0 ]; then
  printf "Please enter description: "
  read DESCRIPTION
  if [ -n "$DESCRIPTION" ]; then
    echo "$DESCRIPTION" >"description.txt"
  fi
  echo ""
fi

# Run custom script, if specified
if [ $NO_CUSTOM_SH -eq 0 -a -n "$BACKUP_CUSTOM_SCRIPT" -a -f "$BACKUP_CUSTOM_SCRIPT" ]; then
  echo "--------------------------------------------------------------------------------"
  echo "* Executing custom script \"$BACKUP_CUSTOM_SCRIPT\""
  # Source script:
  . "$BACKUP_CUSTOM_SCRIPT"
  echo "--------------------------------------------------------------------------------"
fi

# Backup disk partitions/MBR's etc. :
if [ $NO_TRACK0 -ne 1 -a $ONLY_SH -eq 0 ]; then
  backup_disks;
fi

echo "--------------------------------------------------------------------------------"

# Backup selected partitions to images
if [ $NO_IMAGE -eq 0 -a $ONLY_SH -eq 0 ]; then
  backup_partitions;
fi

# Reset terminal
#reset

# Set correct permissions on all files
find . -maxdepth 1 -type f -exec chmod 664 {} \;

# Show current image directory
echo "* Target directory contents($IMAGE_DIR):"
ls -l
echo ""

if [ -n "$FAILED" ]; then
  echo "* Partitions FAILED to backup: $FAILED"
fi

if [ -n "$SUCCESS" ]; then
  echo "* Partitions backuped successfully: $SUCCESS"
else
  echo "* Partitions backuped successfully: none"
fi

# Check integrity of .gz-files:
if [ -n "$BACKUP_IMAGES" ]; then
  echo ""
  echo "* Verifying image(s) ($BACKUP_IMAGES) (CTRL-C to break)..."
  IFS=' '
  for BACKUP_IMAGE in $BACKUP_IMAGES; do
    # Note that pigz seems to hang on broken archives, therefor use gzip
    gzip -tv "$BACKUP_IMAGE"
  done
fi

# Exit (+unmount)
do_exit 0
