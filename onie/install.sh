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

NOS=$(cat installer/nos)
info "Installing $NOS on ${disk}"
sgdisk -p ${disk}

for p in $(seq 3 9); do
    if [ -e ${disk}$p ]; then
       info "Deleting partition ${disk}$p"
       sgdisk -d $p ${disk}
    fi
done
partprobe ${disk}

info "Creating partition ${disk}4"
sgdisk -N 4 ${disk}
sgdisk -c 4:$NOS ${disk}
sgdisk -p ${disk}
partprobe ${disk}

info "Formatting root partition"
ROOT_UUID=9e3f4c2b-0bb2-4ff1-b204-fc83d95d443e
mkfs.ext3 -F -U $ROOT_UUID ${disk}4
root=/mnt
mkdir -p $root
mount ${disk}4 $root

info "Unpacking rootfs"
tar xJf rootfs.tar.xz -C $root
mount -t sysfs -o nodev,noexec,nosuid none $root/sys
mount -t proc -o nodev,noexec,nosuid none $root/proc
mount -t devtmpfs devtmpfs $root/dev
mount -t devpts devpts $root/dev/pts
## The busybox tar doesn't preserve modification
## timestamps. Fix at least the store paths.
info "Fixing timestamps in Nix store"
chroot $root find /nix/store -exec touch -h --date=@0 {} \;

info "Installing GRUB"
echo "UUID=$ROOT_UUID / ext4 errors=remount-ro 0 1" > $root/etc/fstab
echo "${disk}1 /boot/efi vfat umask=0077 0 1" >> $root/etc/fstab
echo "tmpfs /tmp tmpfs defaults 0 0" >> $root/etc/fstab
mkdir -p $root/boot/efi
chroot $root mount /boot/efi

for str in $(blkid ${disk}1); do
    echo $str | grep UUID= >/dev/null && eval $str
done

cat <<EOF >$root/etc/grub.d/42_ONIE_BOOT
#!/bin/sh
set -e

echo "Adding Menu entry to chainload ONIE"
cat <<EOF
menuentry ONIE {
  search --no-floppy --fs-uuid --set=root "$UUID"
  echo 'Loading ONIE ...'
  chainloader /EFI/onie/grubx64.efi
}
EOF
chmod a+x $root/etc/grub.d/42_ONIE_BOOT

chroot $root update-grub
chroot $root grub-install ${disk}

info "Updating EFI boot order"
for b in $(efibootmgr | awk "/$NOS/ { print \$1 }"); do
  num=${b#Boot}
  num=${num%\*}
  efibootmgr -b $num -B
done
. $root/etc/default/grub
efibootmgr -c -d ${disk} -p 1 -L "$NOS" -l "\EFI\\$GRUB_DISTRIBUTOR\grubx64.efi"

sync
reboot
exit 0
