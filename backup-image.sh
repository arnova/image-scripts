#!/bin/bash

MY_VERSION="3.08a"
# ----------------------------------------------------------------------------------------------------------------------
# Image Backup Script with (SMB) network support
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
  if [ "$(id -u)" != "0" ]; then 
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
  [ "$IMAGE_PROGRAM" = "pc" ] && check_binary partclone.dd partclone.ntfs partclone.fat partclone.extfs gzip
  [ "$IMAGE_PROGRAM" = "ddgz" ] && check_binary gzip
}


get_partitions_with_size()
{
  cat /proc/partitions |sed -e '1,2d' -e 's,^/dev/,,' |awk '{ print $4" "$3 }'
}


get_partitions()
{
  get_partitions_with_size |awk '{ print $1 }'
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


show_help()
{
  echo "Usage: backup-image.sh [options] [image-name]"
  echo ""
  echo "Options:"
  echo "--help|-h                   - Print this help"
  echo "--dev|-d={dev1,dev2}        - Backup only these devices/partitions (instead of all)"
  echo "--conf|-c={config_file}     - Specify alternate configuration file"
  echo "--compression|-z=level      - Set gzip compression level (when used). 1=Low but fast (default), 9=High but slow"
  echo "--noconf                    - Don't read the config file"
  echo "--fsa                       - Use fsarchiver for imaging"
  echo "--pi                        - Use partimage for imaging"
  echo "--pc                        - Use partclone + gzip for imaging"
  echo "--ddgz                      - Use dd + gzip for imaging"
  echo "--nonet|-n                  - Don't try to setup networking"
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
NONET=0
NOCONF=0
GZIP_COMPRESSION=1

# Check arguments
unset IFS
for arg in $*; do
  ARGNAME=`echo "$arg" |cut -d= -f1`
  ARGVAL=`echo "$arg" |cut -d= -f2`

  if [ -z "$(echo "$ARGNAME" |grep '^-')" ]; then
    IMAGE_NAME="$ARGVAL"
  else
    case "$ARGNAME" in
      --part|-p|--dev|-d) USER_SOURCE_NODEV=`echo "$ARGVAL" |sed -e 's|,| |g' -e 's|^/dev/||g'`;;
      --compression|-z) GZIP_COMPRESSION="$ARGVAL";;
      --conf|-c) CONF="$ARGVAL";;
      --fsa) IMAGE_PROGRAM="fsa";;
      --ddgz) IMAGE_PROGRAM="ddgz";;
      --pi) IMAGE_PROGRAM="pi";;
      --pc) IMAGE_PROGRAM="pc";;
      --nonet|-n) NONET=1;;
      --noconf) NOCONF=1;;
      --help) show_help; exit 3;;
      *) echo "Bad argument: $ARGNAME"; show_help; exit 4;;
    esac
  fi
done

# Check if configuration file exists
if [ $NOCONF -eq 0 -a -e "$CONF" ]; then
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
if [ -z "$GZIP_COMPRESSION" || $GZIP_COMPRESSION -lt 1 || $GZIP_COMPRESSION -gt 9 ]; then
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

# Sanity check environment
sanity_check;

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

if [ "$NETWORK" != "none" -a -n "$NETWORK" -a "$NONET" != "1" ]; then
  # Setup network (interface)
  configure_network;

  # Try to sync time against the server used, if ntpdate is available
  if which ntpdate >/dev/null 2>&1 && [ -n "$SERVER" ]; then
    ntpdate "$SERVER"
  fi
fi

# Setup CTRL-C handler
trap 'ctrlc_handler' 2

if echo "$IMAGE_NAME" |grep -q '^[\./]'; then
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

    if [ -n "$NETWORK" -a "$NETWORK" != "none" -a -n "$DEFAULT_USERNAME" ]; then
      while true; do
        read -p "Network username ($DEFAULT_USERNAME): " USERNAME
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

echo "* Using image name: $IMAGE_DIR"
echo "* Image working directory: $(pwd)"

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

# Check which partitions to backup, we ignore mounted ones
BACKUP_PARTITIONS=""
IGNORE_PARTITIONS=""
unset IFS
for PART in $PARTITIONS; do
  if grep -E -q "^/dev/${PART}[[:blank:]]" /etc/mtab; then
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
          echo "* Including /dev/$HDD for backup"
          
          # Check if DMA is enabled for HDD
          check_dma /dev/$HDD

          # Dump hdd info for all disks in the current system
          result=`dd if=/dev/$HDD of="track0.$HDD" bs=32768 count=1 2>&1`
          retval=$?
          if [ $retval -ne 0 ]; then
            echo "$result" >&2
            printf "\033[40m\033[1;31mERROR: Track0(MBR) backup from /dev/$HDD failed($retval)! Quitting...\n\033[0m" >&2
            do_exit 8
          fi

          if ! sfdisk -d /dev/$HDD > "partitions.$HDD"; then
            printf "\033[40m\033[1;31mERROR: Partition table backup failed! Quitting...\n\033[0m" >&2
            do_exit 9
          fi

          # Dump fdisk -l info to file
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
          $PARTCLONE -c -s "/dev/$PART" |gzip -$GZIP_COMPRESSION -c >"$TARGET_FILE"
          retval=$?
          if [ ${PIPESTATUS[0]} -ne 0 ]; then
            retval=1
          fi
          ;;
    fsa)  TARGET_FILE="$PART.fsa"
          printf "****** Using fsarchiver to backup /dev/$PART to $TARGET_FILE ******\n\n"
          fsarchiver -v savefs "$TARGET_FILE" "/dev/$PART"
          retval=$?
          ;;
    ddgz) TARGET_FILE="$PART.dd.gz"
          printf "****** Using dd (+gzip) to backup /dev/$PART to $TARGET_FILE ******\n\n"
          dd if="/dev/$PART" bs=4096 |gzip -$GZIP_COMPRESSION -c >"$TARGET_FILE"
          retval=$?
          if [ ${PIPESTATUS[0]} -ne 0 ]; then
            retval=1
          fi
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
if [ -n "$BACKUP_POST_SCRIPT" ]; then
  # Source script:
  . "$BACKUP_POST_SCRIPT"
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
