#!/bin/bash

MY_VERSION="2.01c"
# ----------------------------------------------------------------------------------------------------------------------
# PartImage Restore Script with network support
# Last update: January 27, 2010
# (C) Copyright 2004-2010 by Arno van Amersfoort
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

DEFAULT_CONF="$(dirname $0)/rimage.cnf"
EOL='
'

exit_handler()
{
  echo ""
  # Auto unmount?
  if [ "$AUTO_UNMOUNT" = "1" ] && grep -q " $MOUNT_POINT " /etc/mtab; then
    umount -v "$MOUNT_POINT"
  fi

  stty intr ^C # Back to normal
  exit 1       # Yep, I meant to do that... Kill/hang the shell.
}


# Setup the ethernet interface
configure_network()
{
  CUR_IF=""
  IP_SET=""

  IFS=$EOL
  for LINE in $(ifconfig -a 2>/dev/null); do
    if echo "$LINE" |grep -q -i 'Link encap'; then
      CUR_IF="$(echo "$LINE" |grep -i 'Link encap:ethernet' |grep -v -e '^dummy0' -e '^bond0' -e '^lo' |cut -f1 -d' ')"
    elif echo "$LINE" |grep -q -i 'inet addr:.*Bcast.*Mask.*'; then
      IP_SET="$(echo "$LINE" |sed 's/^ *//g')"
    elif echo "$LINE" |grep -q -i '.*RX packets.*'; then
      if [ -n "$CUR_IF" ]; then
        if [ -z "$IP_SET" ] || ! ifconfig 2>/dev/null |grep -q -e "^$CUR_IF[[:blank:]]"; then
          echo "* Network interface $CUR_IF is not active (yet)"
          
          if echo "$NETWORK" |grep -q -e 'dhcp'; then
            if which dhcpcd >/dev/null 2>&1; then
              printf "* Trying DHCP IP (with dhcpcd) for interface $CUR_IF..."
              # Run dhcpcd to get a dynamic IP
              if ! dhcpcd -L $CUR_IF; then
                echo "FAILED!"
              else
                echo "OK"
                continue
              fi
            elif which dhclient >/dev/null 2>&1; then
              # FIXME: NOT tested!
              printf "* Trying DHCP IP (with dhclient) for interface $CUR_IF..."
              if ! dhclient -1 $CUR_IF; then
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
            if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
              continue
            fi
            
            echo "* Static configuration for interface $CUR_IF"
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
          echo "* Using already configured IP for interface $CUR_IF: "
          echo "  $IP_SET"
        fi
      fi
      CUR_IF=""
      IP_SET=""
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
  check_binary partimage
  
  if [ -z "$MOUNT_TYPE" ] || [ -z "$MOUNT_DEVICE" ] || [ -z "$MOUNT_POINT" ]; then
    printf "\033[40m\033[1;31mERROR: One or more mount options missing in rimage.conf! Quitting...\033[0m\n" >&2
    exit 2
  fi
}


get_partitions()
{
  cat /proc/partitions |awk '{ print $NF }' |sed -e '1,2d' -e 's,^/dev/,,'
}


# Disable HDD write caching
disable_write_cache()
{
  hdparm -W0 "$1" >/dev/null
}


#######################
# Program entry point #
#######################
echo "Partimage RESTORE Script v$MY_VERSION - Written by Arno van Amersfoort"

# Set environment variables to default
CONF="$DEFAULT_CONF"
IMAGE_NAME=""
SUCCESS=""
FAILED=""
USER_TARGET_NODEV=""
CLEAN=0

# Check arguments
unset IFS
for arg in $*; do
  ARGNAME=`echo "$arg" |cut -d= -f1`
  ARGVAL=`echo "$arg" |cut -d= -f2`

  if [ -z "$(echo "$ARGNAME" |grep '^-')" ]; then
    IMAGE_NAME="$ARGVAL"
  else
    case "$ARGNAME" in
      --clean|-clean|-c) CLEAN=1;;
      --device|-device|--dev|-dev|-d) USER_TARGET_NODEV=`echo "$ARGVAL" |sed 's,^/dev/,,g'`;;
      --conf|-c) CONF="$ARGVAL";;
      --name|-n) IMAGE_NAME="$ARGVAL";;
      --help)
      echo "Options:"
      echo "-h, --help           - Print this help"
      echo "--clean              - Even write MBR/partition table if not empty"
      echo "--device={dev}       - Restore image to device {dev} (instead of default)"
      echo "--conf={config_file} - Specify alternate configuration file"
      echo "--name={image_name}  - Use image('s) from directory named like this"
      exit 3 # quit
      ;;
      *) echo "Bad argument: $ARGNAME"; exit 4;;
    esac
  fi
done

# Check if configuration file exists
if [ -e "$CONF" ]; then
  # Source the configuration
  . "$CONF"
else
  echo "ERROR: Missing configuration file ($CONF)!"
  echo "Program aborted"
  exit 1
fi

# Sanity check environment
sanity_check;

# Check if target device exists
if [ -n "$USER_TARGET_NODEV" ]; then
  if ! get_partitions |grep -q -x "$USER_TARGET_NODEV"; then
    echo ""
    printf "\033[40m\033[1;31mERROR: Specified target device $USER_TARGET_NODEV does NOT exist! Quitting...\n\033[0m"
    echo ""
    exit 5
  fi
fi


if [ "$NETWORK" != "none" ]; then
  # Setup network (interface)
  configure_network;

  # Try to sync time against the server used, if ntpdate is available
  if which ntpdate >/dev/null 2>&1 && [ -n "$SERVER" ]; then
    ntpdate "$SERVER"
  fi
fi

# Setup CTRL-break handler
trap 'exit_handler' 2

# Create mount point
if ! mkdir -p "$MOUNT_POINT"; then
  echo ""
  printf "\033[40m\033[1;31mERROR: Unable to create directory for mount point $MOUNT_POINT! Quitting...\n\033[0m"
  echo ""
  exit 7
fi

# Unmount mount point to be used
umount "$MOUNT_POINT" 2>/dev/null

if [ -n "$NETWORK" ] && [ "$NETWORK" != "none" ] && [ -n "$DEFAULT_USERNAME" ]; then
  read -p "Network username ($DEFAULT_USERNAME): " USERNAME
  if [ -z "$USERNAME" ]; then
    USERNAME="$DEFAULT_USERNAME"
  fi

  echo "* Using network username $USERNAME"
  
  # Replace username in our mount arguments (it's a little nasty, I know ;-))
  MOUNT_OPTIONS="-o $(echo "$MOUNT_OPTIONS" |sed "s/$DEFAULT_USERNAME$/$USERNAME/")"
fi

echo "* Mounting $MOUNT_DEVICE on $MOUNT_POINT with options \"-t $MOUNT_TYPE $MOUNT_OPTIONS\""
if ! mount -t $MOUNT_TYPE $MOUNT_OPTIONS "$MOUNT_DEVICE" "$MOUNT_POINT"; then
  echo ""
  printf "\033[40m\033[1;31mERROR: Error mounting $MOUNT_DEVICE on $MOUNT_POINT! Quitting...\n\033[0m"
  echo ""
  exit 6
fi

# Use default or argument specified image name
if [ -z "$IMAGE_NAME" ]; then
  IMAGE_NAME="$DEFAULT_DIR"
fi

DIR_NAME=`echo "$IMAGE_NAME" |tr 'A-Z' 'a-z'`

# Set the directory where the image('s) are
IMAGE_DIR="$MOUNT_POINT/$DIR_NAME"

if [ ! -d "$IMAGE_DIR" ]; then
  echo ""
  printf "\033[40m\033[1;31mERROR: Image directory ($MOUNT_POINT/$DIR_NAME) does NOT exist! Quitting...\n\033[0m"
  echo ""
  exit 7
fi

echo "* Using image directory: $IMAGE_DIR"

if [ -e "$IMAGE_DIR/description.txt" ]; then
  echo "--------------------------------------------------------------------------------"
  cat "$IMAGE_DIR/description.txt"
  echo "--------------------------------------------------------------------------------"
  echo "Press any key to continue"
  read -n 1
fi

# Check whether any image(s) exist
if [ -z "$(find "$IMAGE_DIR/" -maxdepth 1 -name "*.img.gz.000")" ]; then
  echo ""
  printf "\033[40m\033[1;31mERROR: Unable to locate any image files (*.img.gz.000). Network error or empty directory? Quitting...\n\033[0m"
  echo ""
  exit 7
fi

# Restore MBR/track0/partitions
TARGET_NODEV=""
unset IFS
for track0 in "$IMAGE_DIR"/track0.*; do
  HDD_NAME="$(basename "$track0" |sed 's/^track0\.//')"

  # If no target drive specified use default drive from image:
  if [ -n "$USER_TARGET_NODEV" ]; then
    TARGET_NODEV="$USER_TARGET_NODEV";
  else
    if [ -z "$TARGET_NODEV" ]; then
      # Extract drive name from file
      TARGET_NODEV="$HDD_NAME"
    fi
  fi

  # Check if target device exists
  if ! get_partitions |grep -q -x "$TARGET_NODEV"; then
    echo ""
    printf "\033[40m\033[1;31mERROR: Target device /dev/$TARGET_NODEV does NOT exist! Quitting...\n\033[0m"
    echo ""
    exit 5
  fi

  # Check if DMA is enabled for device
  check_dma "/dev/$TARGET_NODEV"

  # Disable write caching
#  disable_write_cache "/dev/$TARGET_NODEV"

  IFS=$EOL
  for PART in `get_partitions |grep -E -x "$TARGET_NODEV""p?[0-9]+"`; do
    # (Try) to unmount all partitions on this device
    if grep -E -q "^/dev/""$PART""[[:blank:]]" /proc/mounts; then
      umount /dev/$PART >/dev/null
    fi

    # Disable all swaps on this device
    if grep -E -q "^/dev/""$PART""[[:blank:]]" /proc/swaps; then
      swapoff /dev/$PART >/dev/null
    fi
  done

  # Only restore track0 (MBR) / partition table if they don't exist already on device
  if ! get_partitions |grep -E -q -x "$TARGET_NODEV""p?[0-9]+" || [ "$CLEAN" = "1" ]; then
    echo "* Resetting partition table on /dev/$TARGET_NODEV"
    if ! printf "o\nw\n" |fdisk /dev/$TARGET_NODEV; then
      printf "\033[40m\033[1;31mERROR: Clearing partition table on /dev/$TARGET_NODEV failed. Press any key to continue or CTRL-C to abort...\n\033[0m"
      read -n1
    fi

    if [ -f "$IMAGE_DIR"/track0.$HDD_NAME ]; then
      echo "* Updating track0(MBR) on /dev/$TARGET_NODEV"
      # NOTE: Without partition table use bs=446 (mbr loader only)
      if ! dd if="$IMAGE_DIR"/track0.$HDD_NAME of=/dev/$TARGET_NODEV bs=32768 count=1; then
        printf "\033[40m\033[1;31mERROR: Track0(MBR) restore failed. Press any key to continue or CTRL-C to abort...\n\033[0m"
        read -n1
      fi

      # Call fdisk to re-read partition table
      if ! printf "w\n" |fdisk /dev/$TARGET_NODEV; then
        printf "\033[40m\033[1;31mERROR: (Re)reading the partition table failed. Press any key to continue or CTRL-C to abort...\n\033[0m"
        read -n1
      fi
    fi

    if [ -f "$IMAGE_DIR"/partitions.$HDD_NAME ]; then
      if ! sfdisk --force /dev/$TARGET_NODEV < "$IMAGE_DIR"/partitions.$HDD_NAME; then
        printf "\033[40m\033[1;31mPartition table restore failed. Press any key to continue or CTRL-C to abort...\n\033[0m"
        read -n1
      fi
    fi
  else
    printf "\033[40m\033[1;31mWARNING: Target device /dev/$TARGET_NODEV already contains a partition table, it will NOT be updated!\n\033[0m"
    echo "To override this you must specify --clean. Press any key to continue or CTRL-C to abort..."
    read -n1
  fi
done


# Test whether the target partition(s) exist:
unset IFS
for IMAGE_FILE in "$IMAGE_DIR"/*.img.gz.000; do
  # Strip extension so we get the actual device name
  PARTITION="$(basename "$IMAGE_FILE" |sed 's/\..*//')"

  # We want another target device than specified in the image name?:
  if [ -n "$USER_TARGET_NODEV" ]; then
    NUM="$(echo "$PARTITION" |sed -e 's,^[a-z]*,,' -e 's,^.*p,,')"
    if ! get_partitions |grep -E -q -x "$USER_TARGET_NODEV""p?""$NUM"; then
      printf "\033[40m\033[1;31mERROR: Unable to find a proper target partition ($NUM on $USER_TARGET_NODEV)! Quitting...\n\033[0m"
      exit 9
    fi
  else
    if ! get_partitions |grep -q -x "$PARTITION"; then
      printf "\033[40m\033[1;31mERROR: Target partition /dev/$PARTITION does NOT exist or is invalid! Quitting...\n\033[0m"
      exit 9
    fi
  fi
done


# Restore the actual image(s):
unset IFS
for IMAGE_FILE in "$IMAGE_DIR"/*.img.gz.000; do
  # Strip extension so we get the actual device name
  PARTITION="$(basename "$IMAGE_FILE" |sed 's/\..*//')"

  # We want another target device than specified in the image name?:
  if [ -n "$USER_TARGET_NODEV" ]; then
    NUM="$(echo "$PARTITION" |sed -e 's,^[a-z]*,,' -e 's,^.*p,,')"
    TARGET_PARTITION="$(get_partitions |grep -E -x -e "$USER_TARGET_NODEV""p?""$NUM")"
  else
    TARGET_PARTITION="$PARTITION"
  fi

  echo "* Selected partition: /dev/$TARGET_PARTITION. Using image file: $IMAGE_FILE"
  partimage -b restore "/dev/$TARGET_PARTITION" "$IMAGE_FILE"
  retval="$?"
  if [ "$retval" != "0" ]; then
    FAILED="${FAILED}${FAILED:+ }${TARGET_PARTITION}"
    printf "\033[40m\033[1;31mERROR: Image restore failed($retval) for $IMAGE_FILE on /dev/$TARGET_PARTITION.\nPress any key to continue or CTRL-C to abort...\n\033[0m"
    read -n1
  else
    SUCCESS="${SUCCESS}${SUCCESS:+ }${TARGET_PARTITION}"
    echo "* $IMAGE_FILE restored to /dev/$TARGET_PARTITION"
  fi
done

# Reset terminal
#reset

# Set this for legacy scripts:
TARGET_DEVICE="$TARGET_NODEV"

# Run custom script(s) (should have .sh extension):
unset IFS
for script in "$IMAGE_DIR"/*.sh; do
  if [ -f "$script" ]; then
    # Source script:
    . "$script"
  fi
done

# Unmount?
if [ "$AUTO_UNMOUNT" = "1" ]; then
  umount -v "$MOUNT_POINT"
fi

# Show current partition status
fdisk -l

# Show result to user
if [ -n "$SUCCESS" ]; then
  echo "* Partitions restored successfully: $SUCCESS"
fi

if [ -n "$FAILED" ]; then
  echo "* Partitions FAILED to restore: $FAILED"
fi

