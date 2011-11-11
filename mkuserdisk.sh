# Auto create d: drive (user disk). Note that this script only works for a
# restore to a single disk!

USER_PART="$TARGET_NODEV""2"

# Umount, just in case
umount /mnt/user 2>/dev/null
umount /mnt/"$USER_PART" 2>/dev/null

if ! cat /proc/partitions |awk '{ print $NF }' |sed s,'^/dev/','', |grep -q "$USER_PART$" || [ "$CLEAN" = "1" ]; then
  echo "* Creating user partition on \"/dev/$TARGET_NODEV\""
  # NTFS partition on 2nd primary:
  printf "n\np\n2\n\n\nt\n2\n7\nw\n" |fdisk /dev/$TARGET_NODEV
  
  echo "* Creating user NTFS filesystem on \"/dev/$USER_PART\""
  mkntfs -L user -Q /dev/$USER_PART
else
  echo "* Skipping creation of NTFS filesystem on \"/dev/$USER_PART\" since it already exists"
fi

