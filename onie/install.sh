#!/bin/sh

set -e

cd $(dirname $0)
cd ..

info () {
    echo
    echo -e "\033[01;32m$@"
    echo -en "\033[0m"
}

. /lib/onie/onie-blkdev-common

## Install NOS on same block device as ONIE
disk=$(onie_get_boot_disk)

NOS="$(cat installer/nos)"
info "Installing $NOS on ${disk}"
sgdisk -p ${disk}

## Delete all partitions except the first 2 (EFI boot loader and ONIE
## boot partition)
partsToDelete=
delOpts=
for p in $(sgdisk -p ${disk} | awk '/^ +[0-9]+ +/ {print $1}'); do
    [ $p -eq 1 -o $p -eq 2 ] && continue
    partsToDelete="$partsToDelete $p"
    delOpts="$delOpts -d $p"
done

info "Checking disk space"
sectorSize=$(sgdisk -p ${disk} | awk '/Logical sector size:/ { print $4 }')
partSize=$(($(sgdisk --pretend $delOpts -N 3 -i 3 ${disk} | \
		  awk '/Partition size:/ { print $3}') * $sectorSize))
rootFsSize=$(cat installer/rootfs-size)
## Make a guess about how large the partition should be to end up with
## a usable system. This should accomodate the file system overhead
## and some spare space to run the system.
estimatedSize=$(echo $rootFsSize | awk '{print int($1 * 1.2)}')
if [ $estimatedSize -gt $partSize ]; then
    echo -e "\033[01;32m"
    echo "It looks like the disk ${disk} does not have enough"
    echo "room for a usable system.  The maximum size of the"
    echo "new parition is ${partSize} bytes, but the root file"
    echo "system with an estimated overhead of 20% is ${estimatedSize} bytes."
    echo -en "\033[01;31m"
    echo "The installation process is aborted, no changes have been made to the system."
    echo "You may have to use efibootmgr to change the boot oder."
    echo -en "\033[0m"
    exit 1
fi

for p in $partsToDelete; do
    if [ -e ${disk}$p ]; then
       info "Deleting partition ${disk}$p"
       sgdisk -d $p ${disk}
    fi
done
partprobe ${disk}

NOS_part=3
NOS_disk=${disk}${NOS_part}
info "Creating partition $NOS_disk"
sgdisk -N $NOS_part ${disk}
sgdisk -c $NOS_part:"$NOS" ${disk}
sgdisk -p ${disk}
partprobe ${disk}

info "Formatting root partition"
ROOT_UUID=9e3f4c2b-0bb2-4ff1-b204-fc83d95d443e
mkfs.ext3 -F -U $ROOT_UUID $NOS_disk
root=/mnt
mkdir -p $root
mount $NOS_disk $root

info "Unpacking rootfs"
tar xJf rootfs.tar.xz -C $root
mount -t sysfs -o nodev,noexec,nosuid none $root/sys
mount -t proc -o nodev,noexec,nosuid none $root/proc
mount -t devtmpfs devtmpfs $root/dev
mount -t devpts devpts $root/dev/pts
ln -s /proc/self/fd $root/dev/fd
## The busybox tar doesn't preserve modification
## timestamps. Fix at least the store paths.
info "Fixing timestamps in Nix store"
chroot $root find /nix/store -exec touch -h --date=@0 {} \;
. /etc/machine.conf
echo "onie_machine=$onie_machine" >$root/etc/machine.conf

fileTree=$root/__platforms/$onie_machine
if [ -d $fileTree ]; then
    info "Installing platform-dependent file tree for platform $onie_machine"
    cp -r $fileTree/* $root/
fi
rm -rf /__platforms

if [ -x $root/post-install-cmd ]; then
   info "Executing post-install command"
   chroot $root /post-install-cmd
   rm $root/post-install-cmd
fi

for str in $(blkid ${disk}1); do
    echo $str | grep UUID= >/dev/null && eval $str
done
EFI_UUID=$UUID

info "Installing GRUB"
echo "UUID=$ROOT_UUID / ext4 errors=remount-ro 0 1" > $root/etc/fstab
echo "UUID=$EFI_UUID /boot/efi vfat umask=0077 0 1" >> $root/etc/fstab
echo "tmpfs /tmp tmpfs defaults 0 0" >> $root/etc/fstab
mkdir -p $root/boot/efi
chroot $root mount /boot/efi

cat <<EOF >$root/etc/grub.d/42_ONIE_BOOT
#!/bin/sh
set -e

echo "Adding Menu entry to chainload ONIE"
cat <<EOF
menuentry ONIE {
  search --no-floppy --fs-uuid --set=root "$EFI_UUID"
  echo 'Loading ONIE ...'
  chainloader /EFI/onie/grubx64.efi
}
EOF
chmod a+x $root/etc/grub.d/42_ONIE_BOOT

## Install platform-specific GRUB defaults
if [ -d $root/etc/default/grub-platforms ]; then
    if [ -e $root/etc/default/grub-platforms/${onie_machine} ]; then
	info "Installing GRUB default for $onie_machine"
	mv $root/etc/default/grub-platforms/${onie_machine} $root/etc/default/grub
    fi
    rm -rf $root/etc/default/grub-platforms
fi

## By default, grub-install infers the EFI boot loader ID from
## /etc/default/grub by the following rules.
##   * If GRUB_DISTRIBUTOR is set, extract the word up to the
##     first space and convert it to lower case
##   * If GRUB_DISTRIBUTOR is not set, use "grub"
## We force the boot loader ID to be "grub" here. Whenever
## grub-install is called from the OS at a later time, it may create a
## new loader in /boot/efi/EFI depending on the setting of
## GRUB_DISTRIBUTOR. That will not be a problem.
bootloader_id=grub
## update-grub needs the device-to-uuid mapping to generate the
## UUID-based root= kernel parameter
mkdir -p $root/dev/disk/by-uuid
ln -s ../../..$NOS_disk $root/dev/disk/by-uuid/$ROOT_UUID
chroot $root update-grub
cat /mnt/boot/grub/grub.cfg
chroot $root grub-install --bootloader-id=${bootloader_id} ${disk}

info "Updating EFI boot order"
for b in $(efibootmgr | awk "/$NOS/ { print \$1 }"); do
  num=${b#Boot}
  num=${num%\*}
  info "Removing existing boot entry $b"
  efibootmgr -b $num -B
done
efibootmgr -c -d ${disk} -p 1 -L "$NOS" -l "\EFI\\${bootloader_id}\grubx64.efi"

sync
reboot
exit 0
