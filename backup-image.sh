#!/bin/bash

MY_VERSION="3.10-BETA8"
# ----------------------------------------------------------------------------------------------------------------------
# Image Backup Script with (SMB) network support
# Last update: June 20, 2013
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
      echo "  $IP_TEST"
    fi

    echo ""
  done
}


# Wrapper for partclone to autodetect filesystem and select the proper partclone.*
partclone_detect()
{
  local PARTCLONE_BIN=""
  local TYPE=`sfdisk -d 2>/dev/null |grep -E "^$1[[:blank:]]" |sed -r -e s!".*Id= ?"!! -e s!",.*"!!`
  case $TYPE in
    # TODO: On Linux we only support ext2/3/4 for now. For eg. btrfs we may need to probe using "fsck -N" or "file -s -b"
    7|17)                           PARTCLONE_BIN="partclone.ntfs";;
    1|4|6|b|c|e|11|14|16|1b|1c|1e)  PARTCLONE_BIN="partclone.fat";;
    fd|83)                          PARTCLONE_BIN="partclone.extfs";;
    *)                              PARTCLONE_BIN="partclone.dd";;
  esac

  check_command_error "$PARTCLONE_BIN"

  echo "$PARTCLONE_BIN"
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
    case "$cmd" in
      /*) path="" ;;
      ip|tc|modprobe|sysctl) path="/sbin/" ;;
      sed|cat|date|uname) path="/bin/" ;;
      *) path="/usr/bin/" ;;
    esac

    if [ -x "$path$cmd" ]; then
      return 0
    fi

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
  check_command_error sed
  check_command_error grep
  check_command_error sfdisk
  check_command_error fdisk
  check_command_error dd
  check_command_error gzip
  check_command_error parted

  [ "$NO_NET" != "0" ] && check_command_error ifconfig
  [ "$NO_MOUNT" != "0" ] && check_command_error mount
  [ "$NO_MOUNT" != "0" ] && check_command_error umount

  [ "$IMAGE_PROGRAM" = "fsa" ] && check_command_error fsarchiver
  [ "$IMAGE_PROGRAM" = "pi" ] && check_command_error partimage
  
  if [ "$IMAGE_PROGRAM" = "pc" -o "$IMAGE_PROGRAM" = "ddgz" ]; then
    if check_command pigz; then
      GZIP="pigz"
    else
      GZIP="gzip"
    fi
  fi

  if [ "$IMAGE_PROGRAM" = "pc" ]; then
    # This is a dummy test for partclone, the actual binary test is in the wrapper
    check_command_error partclone.restore 
  fi
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
    echo ""
    printf "\033[40m\033[1;31mERROR: Image target directory $IMAGE_DIR does NOT exist!\n\033[0m" >&2
    return 2
  fi

  if ! cd "$IMAGE_DIR"; then
    echo ""
    printf "\033[40m\033[1;31mERROR: Unable to cd to image directory $IMAGE_DIR!\n\033[0m" >&2
    return 3
  fi
  
  return 0
}


set_image_dir()
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

      if [ -n "$SERVER" ]; then
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


select_partitions()
{
  local SELECT_PARTITIONS=""

  # Check if target device exists
  if [ -n "$DEVICES" -a "$DEVICES" != "none" ]; then
    unset IFS
    for DEVICE in $DEVICES; do
      if ! get_partitions |grep -q -x "$DEVICE"; then
        echo ""
        printf "\033[40m\033[1;31mERROR: Specified source device /dev/$DEVICE does NOT exist! Quitting...\n\033[0m" >&2
        echo ""
        exit 5
      else
        # Does the device contain partitions?
        if get_partitions |grep -E -q -x "$DEVICE""p?[0-9]+"; then
          SELECT_PARTITIONS="${SELECT_PARTITIONS}$(sfdisk -d /dev/$DEVICE 2>/dev/null |grep '^/dev/' |grep -v -i -e 'Id= 0' -e 'Id= 5' -e 'Id= f' -e 'Id=85' -e 'Id=82' |sed 's,^/dev/,,' |awk '{ printf ("%s ",$1) }')"
        else
          SELECT_PARTITIONS="${SELECT_PARTITIONS}${SELECT_PARTITIONS:+ }${DEVICE}"
        fi
      fi
    done
  else
    # If no argument(s) given, "detect" all partitions (but ignore swap & extended partitions, etc.)
    SELECT_PARTITIONS="${SELECT_PARTITIONS}$(sfdisk -d 2>/dev/null |grep '^/dev/' |grep -v -i -e 'Id= 0' -e 'Id= 5' -e 'Id= f' -e 'Id=85' -e 'Id=82' |sed 's,^/dev/,,' |awk '{ printf ("%s ",$1) }')"
  fi

  # Check which partitions to backup, we ignore mounted ones
  BACKUP_PARTITIONS=""
  IGNORE_PARTITIONS=""
  unset IFS
  for PART in $SELECT_PARTITIONS; do
    if grep -E -q "^/dev/${PART}[[:blank:]]" /etc/mtab || grep -E -q "^/dev/${PART}[[:blank:]]" /proc/swaps; then
      IGNORE_PARTITIONS="${IGNORE_PARTITIONS}${IGNORE_PARTITIONS:+ }$PART"
    else
      BACKUP_PARTITIONS="${BACKUP_PARTITIONS}${BACKUP_PARTITIONS:+ }$PART"
    fi
  done

  if [ -z "$BACKUP_PARTITIONS" ]; then
    printf "\033[40m\033[1;31mWARNING: No partitions to backup!?\nPress <enter> to continue or CTRL-C to abort...\n\033[0m" >&2
    read dummy
  fi
}


backup_partitions()
{
  # Backup all specified partitions:
  unset IFS
  for PART in $BACKUP_PARTITIONS; do
    retval=0
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
            ;;
      pc)   TARGET_FILE="$PART.pc.gz"
            PARTCLONE=`partclone_detect "/dev/$PART"`
            printf "****** Using $PARTCLONE (+${GZIP} -${GZIP_COMPRESSION}) to backup /dev/$PART to $TARGET_FILE ******\n\n"
            { $PARTCLONE -c -s "/dev/$PART"; echo $? >/tmp/.partclone.exitcode; } |$GZIP -$GZIP_COMPRESSION -c >"$TARGET_FILE"
            retval=$?
            if [ $retval -eq 0 ]; then
              retval=`cat /tmp/.partclone.exitcode`
            fi
            ;;
      ddgz) TARGET_FILE="$PART.dd.gz"
            printf "****** Using dd (+${GZIP} -${GZIP_COMPRESSION}) to backup /dev/$PART to $TARGET_FILE ******\n\n"
            { dd if="/dev/$PART" bs=4096; echo $? >/tmp/.dd.exitcode; } |$GZIP -$GZIP_COMPRESSION -c >"$TARGET_FILE"
            retval=$?
            if [ $retval -eq 0 ]; then
              retval=`cat /tmp/.dd.exitcode`
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


select_disks()
{
  BACKUP_DISKS=""

  # Scan all devices/HDDs
  local HDD_NODEV=""
  IFS=$EOL
  for LINE in $(sfdisk -d 2>/dev/null |grep -e '/dev/'); do
    if echo "$LINE" |grep -q '^# '; then
      HDD_NODEV="$(echo "$LINE" |sed 's,.*/dev/,,')"
    elif [ -n "$HDD_NODEV" ]; then
      unset IFS
      for PART in $BACKUP_PARTITIONS; do
        if echo "$LINE" |grep -E -q "^/dev/$PART[[:blank:]]"; then
          echo "* Including /dev/$HDD_NODEV for backup"

          parted_list_fancy "/dev/$HDD_NODEV" |grep -e '^Disk /dev/' -e 'Model: '

          BACKUP_DISKS="${BACKUP_DISKS}${HDD_NODEV} "

          # Mark HDD as done
          HDD_NODEV=""
        fi
      done
    fi
  done

  if [ -z "$BACKUP_DISKS" ]; then
    printf "\033[40m\033[1;31mWARNING: No disks to backup!?\nPress <enter> to continue or CTRL-C to abort...\n\033[0m" >&2
    read dummy
  fi
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

    echo "* Storing partition table for /dev/$HDD_NODEV in sfdisk.$HDD_NODEV..."
    if ! sfdisk -d /dev/$HDD_NODEV > "sfdisk.$HDD_NODEV"; then
      printf "\033[40m\033[1;31mERROR: Partition table backup failed! Quitting...\n\033[0m" >&2
      do_exit 9
    fi

    # Legacy. Must be removed in future releases
    cp "sfdisk.$HDD_NODEV" "partitions.$HDD_NODEV"

    # Dump fdisk -l info to file
    fdisk -l /dev/$HDD_NODEV >"fdisk.$HDD_NODEV"

    # Use wrapped function to only get info for this device
    parted_list /dev/$HDD_NODEV >"parted.$HDD_NODEV"
  done
}


show_help()
{
  echo "Usage: backup-image.sh [options] [image-name]"
  echo ""
  echo "Options:"
  echo "--help|-h                   - Print this help"
  echo "--dev|-d={dev1,dev2}        - Backup only these devices/partitions (instead of all) or \"none\" for no partitions at all"
  echo "--conf|-c={config_file}     - Specify alternate configuration file"
  echo "--compression|-z=level      - Set gzip/pigz compression level (when used). 1=Low but fast (default), 9=High but slow"
  echo "--notrack0                  - Don't backup any track0(MBR)/partition-tables"
  echo "--noconf                    - Don't read the config file"
  echo "--fsa                       - Use fsarchiver for imaging"
  echo "--pi                        - Use partimage for imaging"
  echo "--pc                        - Use partclone + gzip/pigz for imaging"
  echo "--ddgz                      - Use dd + gzip/pigz for imaging"
  echo "--nonet|-n                  - Don't try to setup networking"
  echo "--nomount|-m                - Don't mount anything"
}


load_config()
{
  # Set environment variables to default
  CONF="$DEFAULT_CONF"
  IMAGE_NAME=""
  SUCCESS=""
  FAILED=""
  DEVICES=""
  IMAGE_PROGRAM=""
  NO_NET=0
  NO_CONF=0
  GZIP_COMPRESSION=1
  NO_MOUNT=0
  NO_TRACK0=0

  # Check arguments
  unset IFS
  for arg in $*; do
    ARGNAME=`echo "$arg" |cut -d= -f1`
    ARGVAL=`echo "$arg" |cut -d= -f2 -s`

    case "$ARGNAME" in
      --part|--partitions|-p|--dev|--devices|-d) DEVICES=`echo "$ARGVAL" |sed -e 's|,| |g' -e 's|^/dev/||g'`;;
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
      --help) show_help; exit 3;;
      -*) echo "Bad argument: $ARGNAME"
          show_help
          exit 4
          ;;
       *) if [ -z "$IMAGE_NAME" ]; then
            IMAGE_NAME="$arg"
          else
            echo "Bad command syntax" >&2
            show_help
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

# Determine which partitions to backup
select_partitions;

# Determine which disks to backup
select_disks;

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
echo "* Using image name: $IMAGE_DIR"
echo "* Image working directory: $(pwd)"

# Make sure we're in the correct working directory:
if ! pwd |grep -q "$IMAGE_DIR$"; then
  printf "\033[40m\033[1;31mERROR: Unable to access image directory ($IMAGE_DIR)!\n\033[0m" >&2
  do_exit 7
fi

# Make sure target directory is empty
if [ -n "$(find . -maxdepth 1 -type f)" ]; then
  find . -maxdepth 1 -type f -exec ls -l {} \;
  printf "Current directory is NOT empty. PURGE directory before continueing (Y/N) (CTRL-C to abort)? "
  read answer
  echo ""

  if [ "$answer" = "y" -o "$answer" = "Y" ]; then
    find . -maxdepth 1 -type f -exec rm -vf {} \;
  fi
fi

if [ -n "$IGNORE_PARTITIONS" ]; then
  echo "* Partitions to ignore: $IGNORE_PARTITIONS"
fi

if [ -n "$BACKUP_PARTITIONS" ]; then
  echo "* Partitions to backup: $BACKUP_PARTITIONS"
else
  echo "* Partitions to backup: none"
fi

echo ""

printf "Please enter description: "
read DESCRIPTION
if [ -n "$DESCRIPTION" ]; then
  echo "$DESCRIPTION" >"description.txt"
fi
echo ""

# Backup disk partitions/MBR's etc. :
if [ $NO_TRACK0 -ne 1 ]; then
  backup_disks;
fi

echo "--------------------------------------------------------------------------------"

# Backup selected partitions to images
if [ "$DEVICES" != "none" ]; then
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

# Run custom script, if specified
if [ -n "$BACKUP_POST_SCRIPT" ]; then
  # Source script:
  . "$BACKUP_POST_SCRIPT"
fi

if [ -n "$FAILED" ]; then
  echo "* Partitions FAILED to backup: $FAILED"
fi

if [ -n "$SUCCSS" ]; then
  echo "* Partitions backuped successfully: $SUCCESS"
else
  echo "* Partitions backuped successfully: none"
fi

# Check integrity of .gz-files:
if [ -n "$(find . -maxdepth 1 -type f -iname "*\.gz*" 2>/dev/null)" ]; then
  echo ""
  echo "Verifying .gz images (CTRL-C to break):"
  # Use gzip here as pigz seems to hang on broken archives:
  gzip -tv *\.gz*
fi

# Exit (+unmount)
do_exit 0
