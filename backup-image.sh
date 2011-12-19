#!/bin/bash

MY_VERSION="3.03a"
# ----------------------------------------------------------------------------------------------------------------------
# Image Backup Script with (SMB) network support
# Last update: December 19, 2011
# (C) Copyright 2004-2011 by Arno van Amersfoort
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

DEFAULT_CONF="$(dirname $0)/bimage.cnf"
EOL='
'

do_exit()
{
  echo ""
  
  # Auto unmount?
  if [ "$AUTO_UNMOUNT" = "1" ] && grep -q " $MOUNT_POINT " /etc/mtab; then
    # Go to root else we can't umount
    cd /
    
    # Umount our image repo
    umount -v "$MOUNT_POINT"
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
      CUR_IF="$(echo "$LINE" |grep -i 'link encap:ethernet' |grep -v -e '^dummy0' -e '^bond0' -e '^lo' |cut -f1 -d' ')"
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
            if [ "$answer" = "n" ] || [ "$answer" = "N" ]; then
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


# Wrapper for partclone to autodetect filesystem and select the proper partclone.*
partclone_detect()
{
  local TYPE=`sfdisk -d 2>/dev/null |grep -E "^$1[[:blank:]]" |sed -r -e s!".*Id= ?"!! -e s!",.*"!!`
  case $TYPE in
    # TODO: On Linux we only support ext2/3/4 for now. For eg. btrfs we may need to probe using "fsck -N" or "file -s -b"
    7|17)                           echo "partclone.ntfs";;
    1|4|6|b|c|e|11|14|16|1b|1c|1e)  echo "partclone.fat";;
    fd|83)                          echo "partclone.extfs";;
    *)                              echo "partclone.dd";;
  esac
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


check_binary()
{
  if ! which "$1" >/dev/null 2>&1; then
    printf "\033[40m\033[1;31mERROR: Binary \"$1\" does not exist or is not executable!\033[0m\n" >&2
    printf "\033[40m\033[1;31m       Please, make sure that it is (properly) installed!\033[0m\n" >&2
    exit 2
  fi
}


sanity_check()
{
  # root check
  if [ $UID -ne 0 ]; then
    printf "\033[40m\033[1;31mERROR: Root check FAILED (you MUST be root to use this script)! Quitting...\033[0m\n" >&2
    exit 1
  fi

  check_binary awk
  check_binary find
  check_binary ifconfig
  check_binary sed
  check_binary grep
  check_binary sfdisk
  check_binary fdisk
  check_binary dd
  check_binary mount
  check_binary umount

  [ "$IMAGE_PROGRAM" = "fsa" ] && check_binary fsarchiver
  [ "$IMAGE_PROGRAM" = "pi" ] && check_binary partimage
  [ "$IMAGE_PROGRAM" = "pc" ] && check_binary partclone.dd
  [ "$IMAGE_PROGRAM" = "ddgz" ] && check_binary gzip
  
  if [ -z "$MOUNT_TYPE" ] || [ -z "$MOUNT_DEVICE" ] || [ -z "$MOUNT_POINT" ]; then
    printf "\033[40m\033[1;31mERROR: One or more mount options missing in bimage.conf! Quitting...\033[0m\n" >&2
    exit 2
  fi
}


get_partitions()
{
  cat /proc/partitions |awk '{ print $NF }' |sed -e '1,2d' -e 's,^/dev/,,'
}


show_help()
{
  echo "Usage: backup-image.sh [options] [image-name]"
  echo ""
  echo "Options:"
  echo "--help|-h                   - Print this help"
  echo "--part|-p={dev1,dev2}       - Backup only these partitions (instead of all partitions)"
  echo "--conf|-c={config_file}     - Specify alternate configuration file"
  echo "--fsa                       - Use fsarchiver for imaging"
  echo "--pi                        - Use partimage for imaging"
  echo "--pc                        - Use partclone for imaging"
  echo "--ddgz                      - Use dd + gzip for imaging"
}


#######################
# Program entry point #
#######################
echo "Image BACKUP Script v$MY_VERSION - Written by Arno van Amersfoort"

# Set environment variables to default
CONF="$DEFAULT_CONF"
IMAGE_NAME=""
SUCCESS=""
FAILED=""
USER_SOURCE_NODEV=""
PARTITIONS=""
IMAGE_PROGRAM=""

# Check arguments
unset IFS
for arg in $*; do
  ARGNAME=`echo "$arg" |cut -d= -f1`
  ARGVAL=`echo "$arg" |cut -d= -f2`

  if [ -z "$(echo "$ARGNAME" |grep '^-')" ]; then
    IMAGE_NAME="$ARGVAL"
  else
    case "$ARGNAME" in
      --partitions|--partition|--part|-p) USER_SOURCE_NODEV=`echo "$ARGVAL" |sed -e 's|,| |g' -e 's|^/dev/||g'`;;
      --conf|-c) CONF="$ARGVAL";;
      --fsa) IMAGE_PROGRAM="fsa";;
      --ddgz) IMAGE_PROGRAM="ddgz";;
      --pi) IMAGE_PROGRAM="pi";;
      --pc) IMAGE_PROGRAM="pc";;
      --help) show_help; exit 3;;
      *) echo "Bad argument: $ARGNAME"; show_help; exit 4;;
    esac
  fi
done

# Check if configuration file exists
if [ -e "$CONF" ]; then
  # Source the configuration
  . "$CONF"
else
  echo "ERROR: Missing configuration file ($CONF)!" >&2
  echo "Program aborted" >&2
  exit 1
fi

if [ -z "$IMAGE_PROGRAM" ]; then
  if [ -n "$DEFAULT_IMAGE_PROGRAM" ]; then
    IMAGE_PROGRAM="$DEFAULT_IMAGE_PROGRAM"
  else
    IMAGE_PROGRAM="pc"
  fi  
fi

# Sanity check environment
sanity_check;

if [ -z "$IMAGE_NAME" ]; then
   printf "\033[40m\033[1;31mERROR: You must specify the image-name to be used!\n\033[0m" >&2
   show_help;
   exit 5
fi

# Check if target device exists
if [ -n "$USER_SOURCE_NODEV" ]; then
  unset IFS
  for DEVICE in $USER_SOURCE_NODEV; do
    if ! get_partitions |grep -q -x "$DEVICE"; then
      echo ""
      printf "\033[40m\033[1;31mERROR: Specified source device /dev/$DEVICE does NOT exist! Quitting...\n\033[0m" >&2
      echo ""
      exit 5
    else
      # Does the device contain partitions?
      if get_partitions |grep -E -q -x "$DEVICE""p?[0-9]+"; then
        PARTITIONS="${PARTITIONS}$(sfdisk -d /dev/$DEVICE 2>/dev/null |grep '^/dev/' |grep -v -i -e 'Id= 0' -e 'Id= 5' -e 'Id= f' -e 'Id=85' -e 'Id=82' |sed 's,^/dev/,,' |awk '{ printf ("%s ",$1) }')"
      else
        PARTITIONS="${PARTITIONS}${PARTITIONS:+ }${DEVICE}"
      fi
    fi
  done
else
  # If no argument(s) given, "detect" all partitions (but ignore swap & extended partitions, etc.)
  PARTITIONS="${PARTITIONS}$(sfdisk -d 2>/dev/null |grep '^/dev/' |grep -v -i -e 'Id= 0' -e 'Id= 5' -e 'Id= f' -e 'Id=85' -e 'Id=82' |sed 's,^/dev/,,' |awk '{ printf ("%s ",$1) }')"
fi

if [ "$NETWORK" != "none" ]; then
  # Setup network (interface)
  configure_network;

  # Try to sync time against the server used, if ntpdate is available
  if which ntpdate >/dev/null 2>&1 && [ -n "$SERVER" ]; then
    ntpdate "$SERVER"
  fi
fi

# Setup CTRL-C handler
trap 'ctrlc_handler' 2

# Create mount point
if ! mkdir -p "$MOUNT_POINT"; then
  echo ""
  printf "\033[40m\033[1;31mERROR: Unable to create directory for mount point $MOUNT_POINT! Quitting...\n\033[0m" >&2
  echo ""
  exit 7
fi

# Unmount mount point to be used
umount "$MOUNT_POINT" 2>/dev/null

MOUNT_ARGS="-t $MOUNT_TYPE"

if [ -n "$NETWORK" ] && [ "$NETWORK" != "none" ] && [ -n "$DEFAULT_USERNAME" ]; then
  read -p "Network username ($DEFAULT_USERNAME): " USERNAME
  if [ -z "$USERNAME" ]; then
    USERNAME="$DEFAULT_USERNAME"
  fi

  echo "* Using network username $USERNAME"
  
  # Replace username in our mount arguments (it's a little dirty, I know ;-))
  MOUNT_ARGS="$MOUNT_ARGS -o $(echo "$MOUNT_OPTIONS" |sed "s/$DEFAULT_USERNAME$/$USERNAME/")"
fi

echo "* Mounting $MOUNT_DEVICE on $MOUNT_POINT with arguments \"$MOUNT_ARGS\""
IFS=' '
if ! mount $MOUNT_ARGS "$MOUNT_DEVICE" "$MOUNT_POINT"; then
  echo ""
  printf "\033[40m\033[1;31mERROR: Error mounting $MOUNT_DEVICE on $MOUNT_POINT! Quitting...\n\033[0m" >&2
  echo ""
  exit 6
fi

IMAGE_DIR="$MOUNT_POINT/$TARGET_DIR/$IMAGE_NAME"

if ! mkdir -p "$IMAGE_DIR"; then
  echo ""
  printf "\033[40m\033[1;31mERROR: Unable to create target image directory ($IMAGE_DIR)! Quitting...\n\033[0m" >&2
  echo ""
  do_exit 7
fi

if [ ! -d "$IMAGE_DIR" ]; then
  echo ""
  printf "\033[40m\033[1;31mERROR: Image target directory $IMAGE_DIR does NOT exist! Quitting...\n\033[0m" >&2
  echo ""
  do_exit 5
fi

echo "* Using image directory: $IMAGE_DIR"

if ! cd "$IMAGE_DIR"; then
  echo ""
  printf "\033[40m\033[1;31mERROR: Unable to cd to image directory $IMAGE_DIR! Quitting...\n\033[0m" >&2
  echo ""
  do_exit 5
fi

# Make sure target directory is empty
if [ -n "$(find . -maxdepth 1 -type f)" ]; then
  find . -maxdepth 1 -type f -exec ls -l {} \;
  printf "Current directory is NOT empty. PURGE directory before continuing (Y/N)? "
  read answer
  echo ""

  if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
    find . -maxdepth 1 -type f -exec rm -vf {} \;
  fi
fi

# Check which partitions to backup, we ignore mounted ones
BACKUP_PARTITIONS=""
IGNORE_PARTITIONS=""
unset IFS
for PART in $PARTITIONS; do
  if grep -E -q "^/dev/${PART}[[:blank:]]" /proc/mounts; then
    IGNORE_PARTITIONS="${IGNORE_PARTITIONS}${IGNORE_PARTITIONS:+ }$PART"
  else
    BACKUP_PARTITIONS="${BACKUP_PARTITIONS}${BACKUP_PARTITIONS:+ }$PART"
  fi
done

echo "* Partitions to backup: $BACKUP_PARTITIONS"

if [ -n "$IGNORE_PARTITIONS" ]; then
  echo "* Partitions to ignore: $IGNORE_PARTITIONS"
fi
echo ""

read -p "Please enter description: " DESCRIPTION
if [ -n "$DESCRIPTION" ]; then
  echo "$DESCRIPTION" >"description.txt"
fi
echo ""

# Scan all devices/HDDs
HDD=""
IFS=$EOL
for LINE in $(sfdisk -d 2>/dev/null |grep -e '/dev/'); do
  if echo "$LINE" |grep -q '^# '; then
    HDD="$(echo "$LINE" |sed 's,.*/dev/,,')"
  else
    if [ -n "$HDD" ]; then
      unset IFS
      for PART in $BACKUP_PARTITIONS; do
        if echo "$LINE" |grep -E -q "^/dev/$PART[[:blank:]]"; then
          echo "* Including /dev/$HDD for backup *"    
          
          # Check if DMA is enabled for HDD
          check_dma /dev/$HDD

          # Dump hdd info for all disks in the current system
          if ! dd if=/dev/$HDD of="track0.$HDD" bs=32768 count=1 >/dev/null 2>&1; then
            printf "\033[40m\033[1;31mERROR: Track0(MBR) backup failed!\n\033[0m" >&2
            do_exit 8
          fi

          if ! sfdisk -d /dev/$HDD > "partitions.$HDD"; then
            printf "\033[40m\033[1;31mERROR: Partition table backup failed!\n\033[0m" >&2
            do_exit 9
          fi

          # Dump fdisk info to file
          fdisk -l /dev/$HDD >"fdisk.$HDD"

          # Mark HDD as done
          HDD=""
        fi
      done
    fi
  fi
done

echo ""

# Backup all specified partitions:
unset IFS
for PART in $BACKUP_PARTITIONS; do
  retval=0
  case "$IMAGE_PROGRAM" in
    pi)   TARGET_FILE="$PART.img.gz"
          printf "****** Using partimage to backup /dev/$PART to $TARGET_FILE ******\n\n"
          partimage -z1 -b -d save "/dev/$PART" "$TARGET_FILE"
          retval=$?
          ;;
    pc)   TARGET_FILE="$PART.pc.gz"
          PARTCLONE=`partclone_detect "/dev/$PART"`
          printf "****** Using $PARTCLONE (+gzip) to backup /dev/$PART to $TARGET_FILE ******\n\n"
          $PARTCLONE -c -s "/dev/$PART" |gzip -c >"$TARGET_FILE"
          retval=$?
          ;;
    fsa)  TARGET_FILE="$PART.fsa"
          printf "****** Using fsarchiver to backup /dev/$PART to $TARGET_FILE ******\n\n"
          fsarchiver -v savefs "$TARGET_FILE" "/dev/$PART"
          retval=$?
          ;;
    ddgz) TARGET_FILE="$PART.dd.gz"
          printf "****** Using dd (+gzip) to backup /dev/$PART to $TARGET_FILE ******\n\n"
          dd if="/dev/$PART" bs=64K |gzip -c >"$TARGET_FILE"
          retval=$?
          ;;
  esac
    
  echo ""
  if [ $retval -ne 0 ]; then
    FAILED="${FAILED}${FAILED:+ }$PART"
    printf "\033[40m\033[1;31mERROR: Image backup failed($retval) for $TARGET_FILE from /dev/$PART.\nPress any key to continue or CTRL-C to abort...\n\033[0m" >&2
    read -n1
  else
    SUCCESS="${SUCCESS}${SUCCESS:+ }$PART"
    echo "****** Backuped /dev/$PART to $TARGET_FILE ******"
  fi
  echo ""
done

# Reset terminal
#reset

# Set correct permissions on all files
find . -maxdepth 1 -type f -exec chmod 664 {} \;

# Show current image directory
echo "* Target directory contents($IMAGE_DIR):"
ls -l
echo ""

# Run custom script, if specified
if [ -n "$CUSTOM_POST_SCRIPT" ]; then
  # Source script:
  . "$CUSTOM_POST_SCRIPT"
fi

if [ -n "$FAILED" ]; then
  echo "* Partitions FAILED to backup: $FAILED"
fi

# Show result to user
if [ -n "$SUCCESS" ]; then
  echo "* Partitions backuped successfully: $SUCCESS"
fi

# Check integrity of gzip-files:
if [ -n "$(find . -maxdepth 1 -type f -iname "*.gz" 2>/dev/null)" ]; then
  echo ""
  echo "Verifying gzip images (CTRL-C to break):"
  gzip -tv *.gz
fi

# Exit (+unmount)
do_exit 0
