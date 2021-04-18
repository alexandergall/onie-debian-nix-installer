{ lib, stdenv, callPackage, fetchurl, vmTools, runCommand, debootstrap,
  mount, umount, shadow, rsync, gnutar, xz, gnused, gawk, closureInfo }:

{
  ## List of paths to be installed in nixProfile
  rootPaths ? []
  ## The Nix profile in which to install the service, e.g.
  ## /nix/var/nix/profiles/per-user/root/my-profile
, nixProfile ? "/nix/var/nix/profiles/service"
  ## A list of binary cache URL and keys to add to the image.
  ## Each element is an attribute set with attributes "name"
  ## and "key"
, binaryCaches ? []
  ## A derivation containing a bootstrap profile created by
  ## mk-profile.sh
, bootstrapProfile
  ## A derivation containing a directory tree to be copied
  ## into the root file system after bootstrapping
, fileTree ? (stdenv.mkDerivation {
    name = "empty";
    phases = [ "installPhase" ];
    installPhase = "mkdir $out";
  })
  ## Initial root password.  The default sshd config does
  ## not allow root logins with password authentication.
, rootPassword ? ""
  ## The command to execute in the chroot of the new system
  ## after the profile has been installed.
, activationCmd ? ""
  ## Name of the installer binary, will have ".bin" appended
, installerName ? "onie-installer"
  ## Name to use as the NOS, used as partition label and in
  ## informational messages of install.sh
, NOS ? "NOS"
  ## GRUB configuration
, grubDefault ? builtins.toFile "grub-default" ''
    GRUB_DEFAULT=0
    GRUB_TIMEOUT=5
    GRUB_DISTRIBUTOR="NOS"
    GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0"
    GRUB_CMDLINE_LINUX=""
    GRUB_TERMINAL="console"
  ''
  ## component and version are arbitrary strings which are written to
  ## like-named files in the derivation.  They can be used to identify
  ## the system for which the installer was built, e.g. by a Hydra
  ## post-build script to copy the installer to a specific download
  ## directory.
, component ? ""
, version ? ""
}:

let
  nix-installer = fetchurl {
    url = https://releases.nixos.org/nix/nix-2.3.10/nix-2.3.10-x86_64-linux.tar.xz;
    sha256 = "0d48fq1gs2r599qifwgmp8gb3wdgg3jnsyz1r078cbivslbwv81f";
  };
  defaultBinaryCaches = [
    {
      url = "https://cache.nixos.org";
      key = "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=";
    }
  ];
  aggrBinaryCaches = lib.foldAttrs (n: a: n + " " + a) "" (defaultBinaryCaches ++ binaryCaches);
  serviceClosureInfo = closureInfo { inherit rootPaths; };
  bootstrap = callPackage ./bootstrap-from-profile.nix { inherit bootstrapProfile; };
in vmTools.runInLinuxVM (
  runCommand "onie-installer-debian-${bootstrap.release}" {
    memSize = 4096;
    buildInputs = [ debootstrap mount umount shadow rsync ];
    postVM = ''
      cd xchg

      installer=$out/${installerName}.bin

      echo "Compressing rootfs"
      ${xz}/bin/xz -T0 rootfs.tar

      echo "Creating payload"
      mkdir installer
      cp ${./onie/install.sh} installer/install.sh
      echo ${NOS} >installer/nos
      ${gnutar}/bin/tar cf payload.tar installer rootfs.tar.xz

      echo "Calculating checksum"
      sha1=`sha1sum payload.tar | ${gawk}/bin/awk '{print $1}'`
      cp ${./onie/sharch_body.sh} $installer
      ${gnused}/bin/sed -i -e "s/%%IMAGE_SHA1%%/$sha1/" $installer
      chmod a+wx $installer

      echo "Creating installer"
      cat payload.tar >> $installer
      echo ${component} >$out/component
      echo ${version} >$out/version
    '';
  } (''
    chroot=/chroot
    mkdir $chroot

    exec_chroot () {
      chroot $chroot /bin/env PATH=/bin:/usr/bin:/sbin:/usr/sbin "$@"
    }

    debootstrap --unpack-tarball=${bootstrap.tarball} ${bootstrap.release} $chroot
    cp ${grubDefault} $chroot/etc/default/grub
    mount -t devtmpfs devtmpfs $chroot/dev
    mount -t devpts devpts $chroot/dev/pts
    ln -s /proc/self/fd $chroot/dev/fd
    exec_chroot  /usr/sbin/update-initramfs -u
    echo "localhost" >$chroot/etc/hostname
    if [ "$(ls -A ${fileTree})" ]; then
      cp -r -t $chroot ${fileTree}/*
    fi
    exec_chroot sh -c 'hostname $(cat /etc/hostname)'
    exec_chroot locale-gen
    echo "root:${rootPassword}" | chpasswd --root $chroot -c SHA256

    ### Install the Nix package manager in multi-user mode
    exec_chroot useradd nix
    echo "nix ALL=(ALL) NOPASSWD:ALL" > $chroot/etc/sudoers.d/nix

    ## Trick the installer to believe systemd is running
    mkdir -p $chroot/run/systemd/system

    ## In multi-user mode, Nix builds derivations in a sandbox by default.
    ## The sandbox uses clone(2) with CLONE_NEWUSER, which is not allowed
    ## in a chroot.  The workaround is to disable sandboxing during the
    ## installation (this nix.conf will be overwritten by the installer so
    ## the final system will use sandboxing again). Without
    ## ALLOW_PREEXISTING_INSTALLATION, the installer would consider the
    ## existence of /etc/nix/nix.conf as a sign of a previous install and
    ## abort.
    mkdir -p $chroot/etc/nix
    echo "sandbox = false" >$chroot/etc/nix/nix.conf
    mkdir $chroot/nix-installer
    tar -C $chroot/nix-installer -xf ${nix-installer} --strip-components 1
    exec_chroot sudo -u nix sh -c 'export ALLOW_PREEXISTING_INSTALLATION=1; /bin/bash /nix-installer/install --daemon --no-channel-add --no-modify-profile --daemon-user-count 12 </dev/null'
    rm -rf $chroot/nix-installer

    cat <<EOF >>$chroot/etc/nix/nix.conf
    extra-substituters = ${aggrBinaryCaches.url}
    trusted-substituters = ${aggrBinaryCaches.url}
    trusted-public-keys = ${aggrBinaryCaches.key}
    EOF

    rm $chroot/etc/sudoers.d/nix
    exec_chroot userdel nix

  '' + (lib.optionalString (builtins.length rootPaths > 0) ''
    ### Install the service
    PROFILE=${nixProfile}
    NIX_PATH=/nix/var/nix/profiles/default/bin

    echo
    echo "Copying service closure to chroot"
    rsync -a $(cat ${serviceClosureInfo}/store-paths) $chroot/nix/store
    cat ${serviceClosureInfo}/registration | exec_chroot $NIX_PATH/nix-store --load-db

    echo "Installing initial profile $PROFILE"
    ## Without setting HOME, nix-env creates /homeless-shelter to create
    ## a link for the Nix channel. That confuses the builder, which insists
    ## that the directory does not exist.
    exec_chroot sh -c "HOME=/tmp; $NIX_PATH/nix-env -p $PROFILE -i ${lib.strings.concatStringsSep " " rootPaths} --option sandbox false"

    if [ -n "${activationCmd}" ]; then
      echo "Activating the service with ${activationCmd}"
      exec_chroot ${activationCmd}
    fi
  '') + ''
    umount $chroot/dev/pts
    umount $chroot/dev
    umount $chroot/proc
    umount $chroot/sys

    tar -cf /tmp/xchg/rootfs.tar -C $chroot .
  '')
)
