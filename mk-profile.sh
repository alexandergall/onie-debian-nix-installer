#!/bin/bash
### We want to be able to create reproducible bootstraps of a Debian
### release.  The debootstrap command takes a snapshot of whatever is
### in the repo at that point in time.  We could simply store the
### resulting tarball in the Git repo, but that's ugly and runs into
### Github's file size limitation.  Instead, we do the following
###
###   * Take that snapshot and remove the .deb files
###   * Use nix-prefetch-url to determine the sha256 hashes
###     of the packages
###   * Write the URLs and hashes to a file as a Nix expression
###
### The function in bootstrap-from-profile.nix takes the Nix
### expression form the file, fetches the packages with fetchurl and
### reconstructs the original tarball produced by debootstrap.
###
### This command creates the files
###   bootstrap.tar
###   pkgs.nix
###   release.nix

set -e

usage () {
    echo "usage: $0 <debian-release> [ <additional-packages> ]"
    exit 1
}

packages="linux-image-amd64,initramfs-tools,sudo,zip,unzip,\
          openssh-server,openssh-client,telnet,grub-efi-amd64,\
          efibootmgr,acpi,ethtool,net-tools,wget,curl,rsync,locales,\
          ca-certificates,dbus,xz-utils,emacs-nox"
[ $# -ge 1 ] || usage
release=$1
shift
for pkg in $@; do
    packages="$packages${pkg:+,$pkg}"
done
packages=$(echo $packages | sed -e 's/ *//g')

echo "Creating bootstrap profile for Debian $release"

tarball=bootstrap.tar
chroot=$(mktemp -d)
trap "sudo rm -fr $chroot" INT TERM EXIT

echo "Calling debootstrap with --include=$packages"
sudo /usr/sbin/debootstrap --include="$packages" --make-tarball=$tarball \
			   $release $chroot http://deb.debian.org/debian/
sudo chown $(id -u):$(id -g) $tarball

echo "Removing .deb files from $tarball"
cat $tarball | gunzip | tar -f - --delete --wildcards "var/*.deb" | gzip >$tarball.tmp
mv $tarball.tmp $tarball

declare -A paths
while read name path; do
    paths[$name]=$path
done < <(tar xf $tarball debootstrap/debpaths --to-stdout)

out=pkgs.nix
echo "Creating Nix expression for URLs and hashes"

## Find a timestamp on snapshot.debian.org
timestamp=$(wget -q -O- 'https://snapshot.debian.org/archive/debian/?'$(date '+year=%Y&month=%m&day=%d') | grep -oP '([0-9]{8}T[0-9]{6}Z/)' | tail -1)

exec 3>&1 1>$out
n=0
echo "# Generated from debootstrap --include=$packages"
echo "["
while read name version url; do
    snapshotURL=http://snapshot.debian.org/archive/debian/$timestamp/$(echo $url | sed -e 's/.*\(pool\/.*\)/\1/')
    hash=$(nix-prefetch-url --name none $snapshotURL 2>/dev/null)
    echo "  {"
    echo "    url = $snapshotURL;"
    echo "    sha256 = \"$hash\";"
    echo "    name = \"$(basename ${paths[$name]})\";"
    echo "  }"
    n=$((n+1))
    [ $(($n % 10)) -eq 0 ] && echo -n "." 1>&2
done < <(tar xf $tarball debootstrap/deburis --to-stdout)
echo "]"
exec 1>&3 3>&-
echo
echo "Wrote $n hashes"
echo \"$release\" >release.nix
echo "Created $tarball $out release.nix"
