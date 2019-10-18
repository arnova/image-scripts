#!/bin/bash

MY_VERSION="3.18c"
# ----------------------------------------------------------------------------------------------------------------------
# Image Restore Script with (SMB) network support
# Last update: October 18, 2019
# (C) Copyright 2004-2019 by Arno van Amersfoort
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

# Variable to indicate whether old or new sfdisk is used
OLD_SFDISK=0

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
  if [ "$2" = "y" ]; then
    printf "$1 (Y/n)? "
  else
    printf "$1 (y/N)? "
  fi

  read answer_with_case

  ANSWER=`echo "$answer_with_case" |tr A-Z a-z`

  if [ "$ANSWER" = "y" -o "$ANSWER" = "yes" ]; then
    return 0
  fi

  if [ "$ANSWER" = "n" -o "$ANSWER" = "no" ]; then
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
      printf("%.2fT\n", TB_SIZE)
    }
    else
    {
      GB_SIZE=(SIZE / 1024 / 1024 / 1024)
      if (GB_SIZE > 1.0)
      {
        printf("%.2fG\n", GB_SIZE)
      }
      else
      {
        MB_SIZE=(SIZE / 1024 / 1024)
        if (MB_SIZE > 1.0)
        {
          printf("%.2fM\n", MB_SIZE)
        }
        else
        {
          KB_SIZE=(SIZE / 1024)
          if (KB_SIZE > 1.0)
          {
            printf("%.2fK\n", KB_SIZE)
          }
          else
          {
            printf("%u\n", SIZE)
          }
        }
      }
    }
  }'
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


# Safe (fixed) version of sfdisk since it doesn't always return non-zero when an error occurs
sfdisk_safe()
{
  local IFS=' '

  local result="$(sfdisk $@ 2>&1)"
  local retval=$?

  # Can't just check sfdisk's return code as it is not reliable
  local parse_false="$(echo "$result" |grep -i -e "^Warning.*extends past end of disk" -e "^Warning.*exceeds max")"
  local parse_true="$(echo "$result" |grep -i -e "^New situation:")"
  if [ -n "$parse_false" -o -z "$parse_true" ]; then
    echo "$result" >&2

    # Explicitly show known common errors
#    if [ -n "$parse_false" ]; then
#      printf "\033[40m\033[1;31m${parse_false}\n\033[0m" >&2
#    fi

    if [ $retval -eq 0 ]; then
      retval=8 # Don't show 0, which may confuse user. 8 seems to be the most appropriate return code for this
    fi

    return $retval
  fi

  echo "$result"
  return 0
}


# This function is to handle old vs. new versions of sfdisk. It assumes that any data passed to it is always using DOS partitions (not GPT!)
sfdisk_safe_with_legacy_fallback()
{
  local retval=0

  if [ $OLD_SFDISK -eq 1 ]; then
    # Filter out stuff that old sfdisk doesn't understand
    grep -v -e "^label:" -e "^label-id:" -e "^device:" |sed s!'type='!'Id='! |sfdisk_safe $@
    retval=$?
  else
    # Force DOS partition table
    sfdisk_safe --label dos $@
    retval=$?
  fi

  return $retval
}


# Function to detect whether a device has a GPT partition table
gpt_detect()
{
  if sfdisk -d "$1" |grep -q -E -i -e '^/dev/.*[[:blank:]]Id=ee' -e '^label: gpt'; then
    return 0 # GPT found
  else
    return 1 # GPT not found
  fi
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


# $1 = disk device to get partitions from, if not specified all available partitions are listed
get_partitions()
{
  get_partitions_with_size "$1" |awk '{ print $1 }'
}


# $1 = disk device to get partitions from, if not specified all available partitions are listed
get_disk_partitions_with_type()
{
  local DISK_NODEV=`echo "$1" |sed s,'^/dev/',,`

  if gpt_detect "/dev/$DISK_NODEV" && check_command gdisk; then
    # GPT partition table found
    IFS=$EOL
    for LINE in $(gdisk -l "/dev/$DISK_NODEV" 2>/dev/null |grep -i -E -e '^[[:blank:]]+[0-9]'); do
      NUM="$(echo "$LINE" |awk '{ print $1 }')"
      PART="$(add_partition_number "$DISK_NODEV" "$NUM")"
      TYPE="$(echo "$LINE" |awk '{ print $6 }')"

      echo "$PART $TYPE"
    done
  else
    # MBR/DOS Partitions:
    IFS=$EOL
    for LINE in $(sfdisk -d "/dev/$DISK_NODEV" 2>/dev/null |grep '^/dev/'); do
      PART="$(echo "$LINE" |awk '{ print $1 }' |sed -e s,'^/dev/',,)"
      TYPE="$(echo "$LINE" |awk -F',' '{ print $3 }' |sed -r s,'.*= ?',,)"
      if [ $TYPE -ne 0 ]; then
        echo "$PART $TYPE"
      fi
    done
  fi
}


# Get partitions directly from disk using sfdisk/sgdisk
get_disk_partitions()
{
  get_disk_partitions_with_type "$1" |awk '{print $1 }'
}


# $1 = disk device to get layout from, if not specified all devices are output
get_device_layout()
{
  local DISK_DEV=""

  if [ -n "$1" ]; then
    if echo "$1" |grep -q '^/dev/'; then
      DISK_DEV="$1"
    else
      DISK_DEV="/dev/$1"
    fi
  fi

  # Handle fallback for older versions of lsblk
  result="$(lsblk -i -b -o NAME,FSTYPE,LABEL,UUID,TYPE,PARTTYPE,SIZE "$DISK_DEV" 2>/dev/null)"
  if [ $? -ne 0 ]; then
    result="$(lsblk -i -b -o NAME,FSTYPE,LABEL,UUID,TYPE,SIZE "$DISK_DEV" 2>/dev/null)"
    if [ $? -ne 0 ]; then
      result="$(lsblk -i -b -o NAME,FSTYPE,LABEL "$DISK_DEV" 2>/dev/null)"
      if [ $? -ne 0 ]; then
        echo "WARNING: Unable to obtain lsblk info for \"$DISK_DEV\"" >&2
      fi
    fi
  fi

  if [ -z "$result" ]; then
    return 1
  fi

  IFS=$EOL
  FIRST=1
  echo "$result" |while read LINE; do
    local PART_NODEV=`echo "$LINE" |sed s,'^[^a-z]*',, |awk '{ print $1 }'`

    printf "$LINE\t"

    if [ $FIRST -eq 1 ]; then
      FIRST=0
      printf "SIZEH\n"
    else
      SIZE_HUMAN="$(human_size $(echo "$LINE" |awk '{ print $NF }') |tr ' ' '_')"

      if [ -z "$SIZE_HUMAN" ]; then
        printf "0\n"
      else
        printf "$SIZE_HUMAN\n"
      fi
    fi
  done

  return 0
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


# Show block device partitions, automatically showing either DOS or GPT partition table
list_device_partitions()
{
  local DEVICE="$1"

  if gpt_detect "$DEVICE" && check_command gdisk; then
    # GPT partition table found
    local GDISK_OUTPUT="$(gdisk -l "$DEVICE" 2>/dev/null |grep -i -E -e '^[[:blank:]]+[0-9]' -e '^Number')"
    printf "* GPT partition table:\n${GDISK_OUTPUT}\n\n"
  else
    # MBR/DOS Partitions:
    local FDISK_OUTPUT="$(fdisk -l "$DEVICE" 2>/dev/null |grep -i -E -e '^/dev/' -e 'Device[[:blank:]]+Boot')"
    printf "* DOS partition table:\n${FDISK_OUTPUT}\n\n"
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


# Get partition number from argument and return to stdout
get_partition_number()
{
  echo "$1" |sed -r -e s,'^[/a-z]*',, -e s,'^[0-9]+p',,
}


# Get available devices/disks with /dev/ prefix
get_available_disks()
{
  local DEV_FOUND=""

  IFS=$EOL
  for BLK_DEVICE in /sys/block/*; do
    DEVICE="$(echo "$BLK_DEVICE" |sed s,'^/sys/block/','/dev/',)"
    if echo "$DEVICE" |grep -q -e '/loop[0-9]' -e '/sr[0-9]' -e '/fd[0-9]' -e '/ram[0-9]' || [ ! -b "$DEVICE" ]; then
      continue # Ignore device
    fi

    local SIZE="$(blockdev --getsize64 "$DEVICE" 2>/dev/null)"
    if [ -z "$SIZE" -o "$SIZE" = "0" ]; then
      continue # Ignore device
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

  printf "Waiting for up to date partition table from kernel for $DEVICE..."

  # Retry several times since some daemons can block the re-reread for a while (like dm/lvm)
  IFS=' '
  local TRY=10
  while [ $TRY -gt 0 ]; do
    TRY=$((TRY - 1))

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
  echo "* Disk partitions:" >&2
  echo "$DISK_PARTITIONS" >&2
  echo "" >&2
  echo "* Kernel partitions:" >&2
  echo "$KERNEL_PARTITIONS" >&2
  echo "" >&2
  return 1
}


parse_sfdisk_output()
{
  IFS=$EOL
  while read LINE; do
    if ! echo "$LINE" |grep -i -q ': start=.*size=' || echo "$LINE" |grep -E -i -q '(Id|type)= ?0$'; then
      continue
    fi

    #SFDISK_SOURCE_PART="$(grep -E "^/dev/${IMAGE_PARTITION_NODEV}[[:blank:]]" "partitions.${SOURCE_DISK_NODEV}" |sed -E -e s,'[[:blank:]]+',' ',g -e s,'^ +',,)"
    echo "$LINE" |sed -r -e s!'^ *'!! -e s!'/dev/[a-z]+'!! -e s!'^[0-9]+p'!! -e s!'=[[:blank:]]+'!'='!g -e s!'Id='!'type='! -e s!' ?: ?'!' '! -e s!' ,'!' '!
    #echo "$LINE" |sed -r -e s!'^ */dev/'!! -e s!'[[:blank:]]+'!' '!g
  done
}


parse_gdisk_output()
{
  IFS=$EOL
  while read LINE; do
    if ! echo "$LINE" |grep -q -E '^[[:blank:]]+[0-9]'; then
      continue
    fi

    echo "$LINE" |awk '{ print $1 " "  $2 " " $3 " " $4 " " $5 " " $6 }'
  done
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
    TRY=$((TRY - 1))

    # Somehow using the partprobe binary itself doesn't always work properly, so use blockdev instead
    result="$(blockdev --rereadpt "$DEVICE" 2>&1)"
    retval=$?

    # Wait a sec for things to settle
    sleep 1

    # If blockdev returned success, we're done
    if [ $retval -eq 0 -a -z "$result" ]; then
      break
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
  for CUR_IF in $(ifconfig -a 2>/dev/null |grep '^[a-z]' |sed -r s/'([[:blank:]]|:).*'// |grep -v -e '^dummy' -e '^bond' -e '^lo'); do
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
        continue
      fi
      IP_TEST=`echo "$IF_INFO" |grep -i 'inet .*netmask .*broadcast .*' |sed 's/^ *//g'`
    fi

    if [ -z "$IP_TEST" ] || ! ifconfig 2>/dev/null |grep -q -e "^${CUR_IF}[[:blank:]]" -e "^${CUR_IF}:"; then
      echo "* $CUR_IF ($MAC_ADDR): Not active (yet):"

      if echo "$NETWORK" |grep -q -e 'dhcp'; then
        if check_command dhcpcd; then
          echo "  Trying DHCP IP (with dhcpcd)..."
          # Run dhcpcd to get a dynamic IP
          if dhcpcd -L $CUR_IF; then
            continue
          fi
        elif check_command dhclient; then
          echo "  Trying DHCP IP (with dhclient)..."
          if dhclient -1 $CUR_IF; then
            continue
          fi
        fi
      fi

      if echo "$NETWORK" |grep -q -e 'static'; then
        echo ""
        if ! get_user_yn "* Setup interface $CUR_IF statically"; then
          continue
        fi

        printf "  IP address ($IPADDRESS)? : "
        read USER_IPADDRESS
        if [ -z "$USER_IPADDRESS" ]; then
          USER_IPADDRESS="$IPADDRESS"
          if [ -z "$USER_IPADDRESS" ]; then
            echo "* Skipping configuration of $CUR_IF"
            continue
          fi
        fi

        printf "  Netmask ($NETMASK)? : "
        read USER_NETMASK
        if [ -z "$USER_NETMASK" ]; then
          USER_NETMASK="$NETMASK"
        fi

        printf "  Gateway ($GATEWAY)? : "
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
        echo ""
      fi
    else
      echo "* $CUR_IF ($MAC_ADDR): Using already configured IP: "
      echo "  $IP_TEST"
      echo ""
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
    printf "\033[40m\033[1;31mWARNING: hdparm binary does not exist so not checking/enabling DMA!\n\033[0m" >&2
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
    printf "\033[40m\033[1;31mERROR  : Command(s) \"$(echo "$@" |tr ' ' '|')\" is/are not available!\n\033[0m" >&2
    printf "\033[40m\033[1;31m         Please investigate. Quitting...\n\033[0m" >&2
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
    printf "\033[40m\033[1;31mWARNING: Command(s) \"$(echo "$@" |tr ' ' '|')\" is/are not available!\n\033[0m" >&2
    printf "\033[40m\033[1;31m         Please investigate. This *may* be a problem!\n\033[0m" >&2
    echo ""
  fi

  return $retval
}


sanity_check()
{
  # root check
  if [ "$(id -u)" != "0" ]; then
    printf "\033[40m\033[1;31mERROR: Root check FAILED (you MUST be root to use this script)! Quitting...\n\033[0m" >&2
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
    printf "\033[40m\033[1;31m\nERROR: Image source directory ($IMAGE_DIR) does NOT exist!\n\033[0m" >&2
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
            break # All done: break
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
        echo "* Showing contents of the current directory ($IMAGE_DIR):"
        IFS=$EOL
        find "$IMAGE_DIR" -mindepth 1 -maxdepth 1 -type d |sort |while read ITEM; do
          printf "$(stat -c "%y" "$ITEM" |sed s/'\..*'//)\t$(basename $ITEM)\n"
        done

        printf "\nImage (directory) to use ($IMAGE_DEFAULT): "
        read IMAGE_NAME

        DIR_SELECT=0
        if echo "$IMAGE_NAME" |grep -q "/$"; then
          DIR_SELECT=1
        fi

        TEMP_IMAGE_DIR="$IMAGE_DIR"
        while echo "$IMAGE_NAME" |grep -q '^../'; do
          TEMP_IMAGE_DIR="$(dirname "$TEMP_IMAGE_DIR")" # Get rid of top directory
          IMAGE_NAME="$(echo "$IMAGE_NAME" |sed s:'^../'::)"
        done

        # Get rid of ./ prefix
        IMAGE_NAME="$(echo "$IMAGE_NAME" |sed s:'^\./'::)"

        # Sub-folder handling (=trailing /)
        if echo "$IMAGE_NAME" |grep -q "/$"; then
          TEMP_IMAGE_DIR="$TEMP_IMAGE_DIR/$(echo "$IMAGE_NAME" |sed s:'/*$'::)"
        fi

        if [ ! -d "$TEMP_IMAGE_DIR" ]; then
          printf "\033[40m\033[1;31mERROR: Unable to access directory $TEMP_IMAGE_DIR!\n\033[0m" >&2
          continue # Let user re-select
        fi

        if [ $DIR_SELECT -eq 1 ]; then
          IMAGE_DIR="$TEMP_IMAGE_DIR"
          IMAGE_DEFAULT="."
          continue
        fi

        if [ -z "$IMAGE_NAME" ]; then
           IMAGE_NAME="$IMAGE_DEFAULT"
        fi

        if [ -n "$IMAGE_NAME" -a "$IMAGE_NAME" != "." ]; then
          TEMP_IMAGE_DIR="$TEMP_IMAGE_DIR/$IMAGE_NAME"
        fi

        LOOKUP="$(find "$TEMP_IMAGE_DIR/" -maxdepth 1 -type f -iname "*.img.gz.000" -o -iname "*.fsa" -o -iname "*.dd.gz" -o -iname "*.pc.gz" 2>/dev/null)"
        if [ -z "$LOOKUP" ]; then
          printf "\033[40m\033[1;31m\nERROR: No valid image (directory) specified ($TEMP_IMAGE_DIR)!\n\n\033[0m" >&2
          continue
        fi

        # Try to cd to the image directory
        if ! chdir_safe "$TEMP_IMAGE_DIR"; then
          printf "\033[40m\033[1;31mERROR: Failed to change directory to $TEMP_IMAGE_DIR!\n\033[0m" >&2
          continue
        fi

        IMAGE_DIR="$TEMP_IMAGE_DIR"
        break # All done: break
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
        break
      fi
    else
      # Argument is a disk
      TARGET_DEVICE="/dev/${TARGET_DEVICE_MAP_NODEV}"
      break
    fi
  done

  # We want another target partition than specified in the image name?:
  IFS=' '
  for ITEM in $PARTITIONS; do
    SOURCE_PARTITION_NODEV=`echo "$ITEM" |cut -f1 -d"$SEP"`
    TARGET_PARTITION_MAP=`echo "$ITEM" |cut -f2 -d"$SEP" -s`

    if [ "$SOURCE_PARTITION_NODEV" = "$IMAGE_PARTITION_NODEV" -a -n "$TARGET_PARTITION_MAP" ]; then
      TARGET_DEVICE="$TARGET_PARTITION_MAP"
      break
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
  IFS=' ,'
  for ITEM in $IMAGE_FILES; do
    IMAGE_FILE=`echo "$ITEM" |cut -f1 -d"$SEP" -s`
    TARGET_PARTITION=`echo "$ITEM" |cut -f2 -d"$SEP" -s`

    echo "* Selected partition $TARGET_PARTITION : Using image file \"$IMAGE_FILE\""
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
      echo "** $IMAGE_FILE restored to $TARGET_PARTITION **"
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
      continue # Not specified in --partitions, skip
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
        break
      fi
      #FIXME: Skip check above when --clean is not specified?
    done
  fi

  echo "$SOURCE_NODEV"
}


check_disks()
{
  # Show disks/devices available for restoration
  show_available_disks

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

    echo "* Auto preselecting target device /dev/$IMAGE_TARGET_NODEV for image source \"$IMAGE_SOURCE_NODEV\""

    while true; do
      user_target_dev_select "$IMAGE_TARGET_NODEV"
      TARGET_NODEV="$USER_TARGET_NODEV"

      if [ -z "$TARGET_NODEV" ]; then
        continue
      fi

      # Check if target device exists
      if [ ! -b "/dev/$TARGET_NODEV" ]; then
        echo ""
        printf "\033[40m\033[1;31mERROR: Target device /dev/$TARGET_NODEV does NOT exist!\n\n\033[0m" >&2
        continue
      fi

      local DEVICE_TYPE="$(lsblk -d -n -o TYPE /dev/$TARGET_NODEV)"
      # Make sure it's a real disk
      if [ "$DEVICE_TYPE" = "disk" ]; then
        # Make sure kernel doesn't use old partition table
        if ! partprobe "/dev/$TARGET_NODEV"; then
          echo ""
          if [ $FORCE -ne 1 ]; then
            printf "\033[40m\033[1;31mWARNING: Unable to obtain exclusive access on target device /dev/$TARGET_NODEV! Wrong target device specified and/or mounted partitions?\n\n\033[0m" >&2
            ENTER=1
          else
            printf "\033[40m\033[1;31mERROR: Unable to obtain exclusive access on target device /dev/$TARGET_NODEV! Wrong target device specified and/or mounted partitions? Use --force to override.\n\n\033[0m" >&2
            continue
          fi
        fi

        # Check if DMA is enabled for device
        check_dma "/dev/$TARGET_NODEV"
      fi

      echo ""

      if [ "$IMAGE_SOURCE_NODEV" != "$TARGET_NODEV" ]; then
        update_source_to_target_device_remap "$IMAGE_SOURCE_NODEV" "/dev/$TARGET_NODEV"
      fi
      break
    done

    # Check whether device already contains partitions
    PARTITIONS_FOUND="$(get_partitions "$TARGET_NODEV")"

    if [ -n "$PARTITIONS_FOUND" ]; then
      echo "* NOTE: Target device /dev/$TARGET_NODEV already contains partitions:"
      get_device_layout "$TARGET_NODEV" |sed s,'^','  ',
      echo ""
    fi

    printf "* Image source device \"${IMAGE_SOURCE_NODEV}\""
    if [ -f "device_layout.${IMAGE_SOURCE_NODEV}" ]; then
      echo ":"
      cat "device_layout.${IMAGE_SOURCE_NODEV}" |sed s,'^','  ',
    elif [ -f "partition_layout.${IMAGE_SOURCE_NODEV}" ]; then
      # legacy fallback:
      echo ":"
      cat "partition_layout.${IMAGE_SOURCE_NODEV}" |sed s,'^','  ',
    else
      echo ""
    fi

    echo ""

    if [ $PT_ADD -eq 1 ]; then
      if [ -e "gdisk.${IMAGE_SOURCE_NODEV}" ]; then
        # GPT:
        GDISK_TARGET="$(gdisk -l "/dev/${TARGET_NODEV}" |parse_gdisk_output)"
        if [ -z "$GDISK_TARGET" ]; then
          printf "\033[40m\033[1;31mERROR: Unable to get GPT partitions from device /dev/${TARGET_NODEV} ! Quitting...\n\033[0m" >&2
          do_exit 5
        fi

        local MISMATCH=0
        IFS=$EOL
        for PART_ENTRY in $GDISK_TARGET; do
          # Check entry on source
          if ! cat "gdisk.${IMAGE_SOURCE_NODEV}" |parse_gdisk_output |grep -q -x "${PART_ENTRY}"; then
            MISMATCH=1
            break
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
        # DOS:
        SFDISK_TARGET="$(sfdisk -d "/dev/${TARGET_NODEV}" |parse_sfdisk_output)"
        if [ -z "$SFDISK_TARGET" ]; then
          printf "\033[40m\033[1;31mERROR: Unable to get DOS partitions from device /dev/${TARGET_NODEV} ! Quitting...\n\033[0m" >&2
          do_exit 5
        fi

        MISMATCH=0
        IFS=$EOL
        for PART_ENTRY in $SFDISK_TARGET; do
          if ! cat "sfdisk.${IMAGE_SOURCE_NODEV}" |parse_sfdisk_output |grep -q -x "${PART_ENTRY}"; then
            MISMATCH=1
            break
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
        printf "\033[40m\033[1;31mWARNING: Since target device /dev/$TARGET_NODEV already has a partition-table (+possible bootloader), it will NOT be updated!\n\033[0m" >&2
        echo "To override this you must specify --clean or --pt --mbr..." >&2
        ENTER=1
      else
        if [ $PT_WRITE -eq 0 -a $PT_ADD -eq 0 ]; then
          printf "\033[40m\033[1;31mWARNING: Since target device /dev/$TARGET_NODEV already has a partition-table, it will NOT be updated!\n\033[0m" >&2
          echo "To override this you must specify --clean or --pt..." >&2
          ENTER=1
        fi

        if [ $MBR_WRITE -eq 0 -a -e "track0.${IMAGE_SOURCE_NODEV}" ]; then
          printf "\033[40m\033[1;31mWARNING: Since target device /dev/$TARGET_NODEV already has a partition-table, its MBR will NOT be updated!\n\033[0m" >&2
          echo "To override this you must specify --clean or --mbr..." >&2
          ENTER=1
        fi
      fi
    fi

    if [ $CLEAN -eq 1 -o $MBR_WRITE -eq 1 ] &&
       [ ! -e "track0.${IMAGE_SOURCE_NODEV}" ]; then
      printf "\033[40m\033[1;31mWARNING: track0.${IMAGE_SOURCE_NODEV} does NOT exist! Won't be able to update MBR boot loader!\n\033[0m" >&2
      ENTER=1
    fi

    if [ $CLEAN -eq 1 -o $PT_WRITE -eq 1 -o $PT_ADD -eq 1 ]; then
      if [ ! -e "sfdisk.${IMAGE_SOURCE_NODEV}" -a ! -e "sgdisk.${IMAGE_SOURCE_NODEV}" ]; then
        printf "\033[40m\033[1;31mWARNING: sgdisk/sfdisk.${IMAGE_SOURCE_NODEV} does NOT exist! Won't be able to update partition table!\n\033[0m" >&2
        ENTER=1
      fi

      if [ -e "sgdisk.${IMAGE_SOURCE_NODEV}" ]; then
        # Simulate GPT partition table restore
        result="$(sgdisk --pretend --load-backup="sgdisk.${IMAGE_SOURCE_NODEV}" "/dev/${TARGET_NODEV}" >/dev/null 2>&1)"

        if [ $? -ne 0 ]; then
          echo "$result" >&2
          if [ $FORCE -eq 1 ]; then
            printf "\033[40m\033[1;31mWARNING: Invalid GPT partition table (disk too small?)!\n\033[0m" >&2
            ENTER=1
          else
            printf "\033[40m\033[1;31mERROR: Invalid GPT partition table (disk too small?)! Quitting (--force to override)...\n\033[0m" >&2
            do_exit 5
          fi
        fi
      elif [ -e "sfdisk.${IMAGE_SOURCE_NODEV}" ]; then
        # Simulate DOS partition table restore
        result="$(cat "sfdisk.${IMAGE_SOURCE_NODEV}" |sfdisk_safe_with_legacy_fallback --force -n "/dev/${TARGET_NODEV}" 2>&1)"
        if [ $? -ne 0 ]; then
          if [ $FORCE -eq 1 ]; then
            printf "\033[40m\033[1;31m\nWARNING: Invalid DOS partition table (disk too small?)!\n\033[0m" >&2
            ENTER=1
          else
            echo "$result" >&2
            printf "\033[40m\033[1;31m\nERROR: Invalid DOS partition table (disk too small?)! Quitting (--force to override)...\n\033[0m" >&2
            do_exit 5
          fi
        fi
      fi
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
      # Completely zap GPT, MBR and legacy partition data, if we're using GPT on one of the devices
      sgdisk --zap-all /dev/$TARGET_NODEV >/dev/null 2>&1

      # Clear GPT entries before zapping them else sgdisk --load-backup (below) may complain
#      sgdisk --clear /dev/$TARGET_NODEV >/dev/null 2>&1
    fi

    TRACK0_CLEAN=0
    if [ -z "$PARTITIONS_FOUND" -o $CLEAN -eq 1 ] && [ $NO_TRACK0 -eq 0 ]; then
      TRACK0_CLEAN=1
    fi

    DD_SOURCE="track0.${IMAGE_SOURCE_NODEV}"
    # Check for MBR restore:
    if [ $MBR_WRITE -eq 1 -o $TRACK0_CLEAN -eq 1 ]; then
      if [ -e "$DD_SOURCE" ]; then
        GDISK_FILE="gdisk.${IMAGE_SOURCE_NODEV}"
        if grep -qi 'GPT: present' "$GDISK_FILE" 2>/dev/null; then
          echo "* Updating GPT protective MBR on /dev/$TARGET_NODEV from $DD_SOURCE:"

          if [ $CLEAN -eq 1 -o -z "$PARTITIONS_FOUND" ]; then
            # Complete MBR including legacy DOS partition table
            dd if="$DD_SOURCE" of=/dev/$TARGET_NODEV bs=512 count=1
            retval=$?
          else
            # Complete MBR but excluding legacy DOS partition table
            dd if="$DD_SOURCE" of=/dev/$TARGET_NODEV bs=446 count=1
            retval=$?
          fi
        else
          echo "* Updating track0(MBR) on /dev/$TARGET_NODEV from $DD_SOURCE:"

          if [ $CLEAN -eq 1 -o -z "$PARTITIONS_FOUND" ]; then
            # For clean or empty disks always try to use a full 1MiB of DD_SOURCE else Grub2 may not work.
            dd if="$DD_SOURCE" of=/dev/$TARGET_NODEV bs=512 count=2048
            retval=$?
          else
            # FIXME: Need to detect the empty space before the first partition since GRUB2 may be longer than 32256 bytes!
            dd if="$DD_SOURCE" of=/dev/$TARGET_NODEV bs=446 count=1 && dd if="$DD_SOURCE" of=/dev/$TARGET_NODEV bs=512 seek=1 skip=1 count=62
            retval=$?
          fi
        fi

        if [ $retval -ne 0 ]; then
          printf "\033[40m\033[1;31mERROR: Track0(MBR) update from $DD_SOURCE to /dev/$TARGET_NODEV failed($retval). Quitting...\n\033[0m" >&2
          do_exit 5
        fi
        echo ""
        PARTPROBE=1
      fi
    fi

    # Check for partition restore
    if [ $TRACK0_CLEAN -eq 1 -o $PT_WRITE -eq 1 -o $PT_ADD -eq 1 ]; then
      if [ -e "$SGDISK_FILE" ]; then
        echo "* Updating partition-table on /dev/$TARGET_NODEV:"
        result="$(sgdisk_safe --load-backup="$SGDISK_FILE" /dev/$TARGET_NODEV 2>&1)"
        retval=$?

        if [ $retval -ne 0 ]; then
          echo "$result" >&2
          printf "\033[40m\033[1;31mPartition-table restore failed($retval). Quitting...\n\033[0m" >&2
          do_exit 5
        else
          echo "$result"
        fi
        echo ""
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
          echo "* Updating partition-table on /dev/$TARGET_NODEV:"
          result="$(cat "$SFDISK_FILE" |sfdisk_safe_with_legacy_fallback --force --no-reread /dev/$TARGET_NODEV 2>&1)"
          retval=$?

          # Make sure partition was properly written
          if [ $retval -ne 0 ] || ! echo "$result" |grep -i -e "^Successfully wrote" -e "^The partition table has been altered"; then
            echo "$result" >&2
            echo "" >&2

            printf "\033[40m\033[1;31mPartition-table restore failed($retval). Quitting...\n\033[0m" >&2
            do_exit 5
          fi

          echo "$result" #|grep -i -e 'Success'

          # Make sure we restore the PARTUUID else e.g. Windows 10 fails to boot
          echo ""
          echo "* Updating DOS partition UUID on /dev/$TARGET_NODEV"
          result=`dd if="$DD_SOURCE" of=/dev/$TARGET_NODEV bs=1 seek=440 skip=440 count=6 2>&1`
          retval=$?
          if [ $retval -ne 0 ]; then
            echo "$result" >&2
            printf "\033[40m\033[1;31mERROR: DOS partition UUID update from $DD_SOURCE to /dev/$TARGET_NODEV failed($retval). Quitting...\n\033[0m" >&2
            do_exit 5
          fi

          echo ""
          PARTPROBE=1
        fi
      fi
      list_device_partitions /dev/$TARGET_NODEV
    fi

    if [ $PARTPROBE -eq 1 ]; then
      # Wait for kernel to reread partition table
      if partprobe "/dev/$TARGET_NODEV" && part_check "/dev/$TARGET_NODEV"; then
        : # No-op
      elif [ $FORCE -ne 1 ]; then
        printf "\033[40m\033[1;31mWARNING: (Re)reading the partition-table failed! Use --force to override.\n\033[0m" >&2
        do_exit 5
      fi
    fi
  done
}


check_image_files()
{
  IMAGE_FILES=""
  while [ -z "$IMAGE_FILES" ]; do
    if [ -n "$PARTITIONS" ]; then
      IFS=' ,'
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
        PARTITIONS="${PARTITIONS}${PARTITIONS:+ }${SOURCE_NODEV}"

        if echo "$IMAGE_FILES" |grep -q -e "${SEP}${TARGET_PARTITION}$" -e "${SEP}${TARGET_PARTITION} "; then
          printf "\033[40m\033[1;31m\nERROR: Found multiple image files for partition $TARGET_PARTITION! Quitting...\n\033[0m" >&2
          do_exit 5
        fi

        # Add item to list
        IMAGE_FILES="${IMAGE_FILES}${IMAGE_FILES:+ }${IMAGE_FILE}${SEP}${TARGET_PARTITION}"
      done

      printf "* Select source partition(s) to restore (default=$PARTITIONS): "
      read USER_PARTITIONS
      if [ -n "$USER_PARTITIONS" ]; then
        PARTITIONS="$USER_PARTITIONS"
        IMAGE_FILES="" # Redetermine which image files to include
      fi
    fi
  done

  if [ -z "$IMAGE_FILES" ]; then
    printf "\033[40m\033[1;31m\nERROR: No (matching) image files found to restore! Quitting...\n\033[0m" >&2
    do_exit 5
  fi

  # Make sure the proper binaries are available
  IFS=' ,'
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
  IFS=' ,'
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


compare_sfdisk_partition()
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
    printf "\033[40m\033[1;31mWARNING: Target partition $TARGET_NUM(size=$TARGET_SIZE) is smaller than source partition $SOURCE_NUM(size=$SOURCE_SIZE)!\n\033[0m" >&2
    retval=1
  fi

  # Target is bigger?
  if [ $SOURCE_SIZE -lt $TARGET_SIZE ]; then
    printf "\033[40m\033[1;31mWARNING: Target partition $TARGET_NUM(size=$TARGET_SIZE) is bigger than source partition $SOURCE_NUM(size=$SOURCE_SIZE)!\n\033[0m" >&2
    retval=1
  fi

  return $retval
}


compare_gdisk_partition()
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
    printf "\033[40m\033[1;31mWARNING: Target partition $TARGET_NUM has different code/name than source partition $SOURCE_NUM!\n\033[0m" >&2
    retval=1
  fi

  # NOTE: gdisk report size in MiB/GiB etc. so that can't be used for exact size matching
  #       instead calculate size from start/end sector. Assume 512 byte logical sector size
  local SOURCE_SIZE="$(echo "$SOURCE_PART" |awk '{ print ($3 - $2) * 512 }')"
  local TARGET_SIZE="$(echo "$TARGET_PART" |awk '{ print ($3 - $2) * 512 }')"

  # Target is smaller?
  if [ $SOURCE_SIZE -gt $TARGET_SIZE ]; then
    printf "\033[40m\033[1;31mWARNING: Target partition $TARGET_NUM(size=$TARGET_SIZE) is smaller than source partition $SOURCE_NUM(size=$SOURCE_SIZE)!\n\033[0m" >&2
    retval=1
  fi

  # Target is bigger?
  if [ $SOURCE_SIZE -lt $TARGET_SIZE ]; then
    printf "\033[40m\033[1;31mWARNING: Target partition $TARGET_NUM(size=$TARGET_SIZE) is bigger than source partition $SOURCE_NUM(size=$SOURCE_SIZE)!\n\033[0m" >&2
    retval=1
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
  IFS=' ,'
  for ITEM in $IMAGE_FILES; do
    IMAGE_FILE=$(echo "$ITEM" |cut -f1 -d"$SEP" -s)
    TARGET_PARTITION=$(echo "$ITEM" |cut -f2 -d"$SEP" -s)

    # Strip extension so we get the actual device name
    IMAGE_PARTITION_NODEV=$(echo "$IMAGE_FILE" |sed 's/\..*//')
    SOURCE_DISK_NODEV=$(get_partition_disk "$IMAGE_PARTITION_NODEV")
    TARGET_DISK=$(get_partition_disk "$TARGET_PARTITION")

    # FIXME: What to do if one translates to a disk?
    if [ -z "$SOURCE_DISK_NODEV" -o -z "$TARGET_DISK" ]; then
      continue # No partitions on this device
    fi

    if [ -e "gdisk.${SOURCE_DISK_NODEV}" ]; then
      GDISK_TARGET_PART="$(gdisk -l "$TARGET_DISK" |parse_gdisk_output |grep -E "^$(get_partition_number "$TARGET_PARTITION")[[:blank:]]")"
      if [ -n "$GDISK_TARGET_PART" ]; then
        GDISK_SOURCE_PART="$(cat "gdisk.${SOURCE_DISK_NODEV}" 2>/dev/null |parse_gdisk_output |grep -E "^$(get_partition_number "$IMAGE_PARTITION_NODEV")[[:blank:]]" )"

        echo "* Source GPT partition: $GDISK_SOURCE_PART"
        echo "* Target GPT partition: $GDISK_TARGET_PART"

        # Match partition with what we have stored in our partitions file
        if [ -z "$GDISK_SOURCE_PART" ]; then
          printf "\033[40m\033[1;31m\nWARNING: GPT partition /dev/$IMAGE_PARTITION_NODEV can not be found in partition source files!\n\033[0m" >&2
          echo ""
          MISMATCH=1
          continue
        fi

        if ! compare_gdisk_partition "$GDISK_SOURCE_PART" "$GDISK_TARGET_PART"; then
          MISMATCH=1
        fi
      else
        printf "\033[40m\033[1;31m\nERROR: Unable to detect target partition $TARGET_PARTITION! Quitting...\n\033[0m" >&2
        do_exit 5
      fi
    else
      SFDISK_TARGET_PART="$(sfdisk -d "$TARGET_DISK" 2>/dev/null |parse_sfdisk_output |grep -E "^$(get_partition_number ${TARGET_PARTITION})[ ,]")"
      if [ -n "$SFDISK_TARGET_PART" ]; then
        # DOS partition found
        SFDISK_SOURCE_PART=""
        if [ -f "sfdisk.${SOURCE_DISK_NODEV}" ]; then
          SFDISK_SOURCE_PART="$(cat "sfdisk.${SOURCE_DISK_NODEV}" |parse_sfdisk_output |grep -E "^$(get_partition_number ${IMAGE_PARTITION_NODEV})[ ,]")"
        elif [ -f "partitions.${SOURCE_DISK_NODEV}" ]; then
          # If empty, try old (legacy) file
          if grep -q '^# partition table of' "partitions.${SOURCE_DISK_NODEV}"; then
            SFDISK_SOURCE_PART="$(cat "partitions.${SOURCE_DISK_NODEV}" |parse_sfdisk_output |grep -E "^$(get_partition_number ${IMAGE_PARTITION_NODEV})[[:blank:]]")"
          fi
        fi

        echo "* Source DOS partition: $SFDISK_SOURCE_PART"
        echo "* Target DOS partition: $SFDISK_TARGET_PART"

        # Match partition with what we have stored in our partitions file
        if [ -z "$SFDISK_SOURCE_PART" ]; then
          printf "\033[40m\033[1;31m\nWARNING: DOS partition /dev/$IMAGE_PARTITION_NODEV can not be found in the partition source files!\n\033[0m" >&2
          echo ""
          MISMATCH=1
          continue
        fi

        # Check geometry/type of partition
        if ! compare_sfdisk_partition "$SFDISK_SOURCE_PART" "$SFDISK_TARGET_PART"; then
          MISMATCH=1
        fi
      fi
    fi
  done

  echo ""

  if [ $MISMATCH -ne 0 ]; then
    printf "\033[40m\033[1;31mWARNING: One or more target partitions mismatch with source partitions!\n\033[0m" >&2
    if ! get_user_yn "Continue anyway"; then
      echo "Aborted by user..."
      do_exit 5
    fi
    return 1
  fi

  return 0
}


# Create swap partitions on all target devices
create_swaps()
{
  local SWAP_COUNT=1

  IFS=' '
  for DEVICE in $TARGET_DEVICES; do
    IFS=$EOL
    get_disk_partitions_with_type "$DEVICE" 2>/dev/null |grep -E -i "[[:blank:]]820?0?$" |while read LINE; do
      PART="/dev/$(echo "$LINE" |awk '{ print $1 }')"
      printf "* Creating swapspace on $PART: "
      if ! mkswap -L "swap${SWAP_COUNT}" "$PART"; then
        printf "\033[40m\033[1;31mWARNING: mkswap failed for $PART\n\033[0m" >&2
      fi
      SWAP_COUNT=$((SWAP_COUNT + 1))
    done
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
load_config $*

# Sanity check environment
sanity_check

if [ "$NETWORK" != "none" -a -n "$NETWORK" -a $NO_NET != 1 ]; then
  # Setup network (interface)
  configure_network

  # Try to sync time against the server used, if ntpdate is available
  if [ -n "$SERVER" ] && check_command ntpdate; then
    ntpdate "$SERVER"
  fi
fi

# Setup CTRL-C handler
trap 'ctrlc_handler' 2

set_image_source_dir

echo "--------------------------------------------------------------------------------"
echo "* Image name: $(basename $IMAGE_DIR)"
echo "* Image working directory: $(pwd)"

# Make sure we're in the correct working directory:
if ! pwd |grep -q "$IMAGE_DIR$"; then
  printf "\033[40m\033[1;31mERROR: Unable to access image directory ($IMAGE_DIR)!\n\033[0m" >&2
  do_exit 7
fi

# Check for GPT partitions in source
if [ -n "$(find . -maxdepth 1 -type f -iname "sgdisk.*" -o -iname "gdisk.*")" ]; then
  check_command_error gdisk
  check_command_error sgdisk
fi

# Check whether old or new sfdisk is used
if ! sfdisk --label dos -v >/dev/null 2>&1; then
  OLD_SFDISK=1
fi

# Check target disks
check_disks

check_image_files

# Check target partitions
check_partitions

# Show info about target devices to be used
show_target_devices

if [ -e "description.txt" ]; then
  echo "--------------------------------------------------------------------------------"
  cat "description.txt"
fi

echo "--------------------------------------------------------------------------------"

if [ $ONLY_SH -eq 0 ]; then
  if [ $CLEAN -eq 1 ]; then
    printf "\033[40m\033[1;31m* WARNING: MBR/track0 & partition-table will ALWAYS be (over)written (--clean)!\n\033[0m" >&2
  else
    if [ $PT_WRITE -eq 1 ]; then
      echo "* WARNING: Partition-table will ALWAYS be (over)written (--pt)!" >&2
    fi

    if [ $MBR_WRITE -eq 1 ]; then
      echo "* WARNING: MBR/track0 will ALWAYS be (over)written (--mbr)!" >&2
    fi
  fi
fi

echo ""

if ! get_user_yn "Continue with restore"; then
  echo "Aborted by user..."
  do_exit 1
else
  echo ""
fi

# Restore MBR/partition tables
if [ $ONLY_SH -eq 0 ]; then
  restore_disks
fi

if [ $ONLY_SH -eq 0 ]; then
  # Make sure the target is sane
  test_target_partitions

  if [ $NO_IMAGE -eq 0 ]; then
    # Restore images to partitions
    restore_partitions
  fi
fi

if [ $CLEAN -eq 1 -a $ONLY_SH -eq 0 ]; then
  create_swaps
fi

# Set this for legacy scripts:
TARGET_DEVICE=`echo "$TARGET_DEVICES" |cut -f1 -d' '` # Pick the first device (probably sda)
TARGET_NODEV=`echo "$TARGET_DEVICE" |sed s,'^/dev/',,`
USER_TARGET_NODEV="$TARGET_NODEV"

# Run custom script(s) (should have .sh extension):
if [ $NO_CUSTOM_SH -eq 0 ] && ls ./*.sh >/dev/null 2>&1; then
  echo "--------------------------------------------------------------------------------"
  unset IFS
  for script in $(find . -maxdepth 1 -type f -iname "*.sh"); do
    # Source script:
    echo "* Executing custom script \"$script\""
    . ./"$script"
  done
fi

echo "--------------------------------------------------------------------------------"

# Show current partition status.
IFS=' '
for DEVICE in $TARGET_DEVICES; do
  echo "* $DEVICE: $(show_block_device_info "$DEVICE")"
  get_device_layout "$DEVICE"
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
