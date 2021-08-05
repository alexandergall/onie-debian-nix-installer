{ lib, stdenv, callPackage, fetchurl, vmTools, runCommand, debootstrap,
  mount, umount, shadow, rsync, gnutar, xz, gnused, gawk, closureInfo }:

{
  ## List of paths whose closure will be added to the Nix store
  ## of the install image
  rootPaths ? []
  ## A command that will be executed inside a chroot after Nix has
  ## been installed into the root file system
, postRootFsCreateCmd ? null
  ## A command that will be executed inside a chroot after unpacking
  ## the root file system on the installation target
, postRootFsInstallCmd ? null
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
  ## Set of users to create
, users ? {}
  ## Name of the installer binary, will have ".bin" appended
, installerName ? "onie-installer"
  ## Name to use as the NOS, used as partition label and in
  ## informational messages of install.sh
, NOS ? "NOS"
  ## GRUB configuration to be installed in /etc/default/grub.  The
  ## values of the attributes must be store paths that consis of a
  ## single file in the format expected by /etc/default/grub. The
  ## default file is installed as /etc/default/grub. All other
  ## attributes are installed as
  ## /etc/default/grub-platforms/<attribute>.  At install time, it is
  ## checked whether the file
  ## /etc/default/grub-platforms/<onie_machine> exists.  If so, it is
  ## copied to /etc/default/grub. /etc/default/grub-platforms is deleted.
, grubDefault ? {}
  ## component and version are arbitrary strings which are written to
  ## like-named files in the derivation.  They can be used to identify
  ## the system for which the installer was built, e.g. by a Hydra
  ## post-build script to copy the installer to a specific download
  ## directory.
, component ? ""
, version ? ""
  ## Size of the VM in MiB
, memSize ? 4096
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
  bootstrap = callPackage ./bootstrap-from-profile.nix { inherit bootstrapProfile; };
  rootClosureInfo = closureInfo { inherit rootPaths; };
  cpGrubDefault = platform: file:
    ''
      mkdir -p $chroot/etc/default/grub-platforms
      if [ ${platform} == default ]; then
        cp ${file} $chroot/etc/default/grub
      else
        cp ${file} $chroot/etc/default/grub-platforms/${platform}
      fi
    '';
  cpGrubDefaults = builtins.concatStringsSep "\n"
    (lib.mapAttrsToList cpGrubDefault ({
      default = builtins.toFile "grub-default" ''
        GRUB_DEFAULT=0
        GRUB_TIMEOUT=5
        GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0"
        GRUB_CMDLINE_LINUX=""
        GRUB_TERMINAL="console"
      '';
    } // grubDefault));
  mkUser = user: spec':
    let
      spec = {
        useraddArgs = "";
        sshPublicKey = "";
        sudo = true;
        passwordlessSudo = true;
      } // spec';
    in ''
      exec_chroot useradd ${spec.useraddArgs} ${user}
    '' + lib.optionalString (spec ? password) ''
      echo "${user}:${spec.password}" | chpasswd --root $chroot -c SHA256
    '' + ''
      if [ -n "${spec.sshPublicKey}" ]; then
         mkdir -p $chroot/home/${user}/.ssh
         echo ${spec.sshPublicKey} >$chroot/home/${user}/.ssh/authorized_keys
      fi
      exec_chroot chown -R ${user}:${user} /home/${user}
      if [ -n "${builtins.toString spec.sudo}" ]; then
        echo "${user} ALL=(ALL:ALL) ${if spec.passwordlessSudo then "NOPASSWD:" else ""} ALL" >$chroot/etc/sudoers.d/${user}
      fi
    '';
  mkUsers = with builtins;
    concatStringsSep "\n" (lib.attrValues (mapAttrs mkUser users));
in vmTools.runInLinuxVM (
  runCommand "onie-installer-debian-${bootstrap.release}" {
    inherit memSize;
    buildInputs = [ debootstrap mount umount shadow rsync ];
    postVM = ''
      cd xchg

      installer=$out/${installerName}.bin

      echo "Compressing rootfs"
      ${xz}/bin/xz -T0 rootfs.tar -c | cat >$out/rootfs.tar.xz

      echo "Creating payload"
      cd $out
      mkdir installer
      cp ${./onie/install.sh} installer/install.sh
      echo ${NOS} >installer/nos
      ${gnutar}/bin/tar cf payload.tar installer rootfs.tar.xz
      rm -rf installer rootfs.tar.xz

      echo "Calculating checksum"
      sha1=`sha1sum payload.tar | ${gawk}/bin/awk '{print $1}'`
      cp ${./onie/sharch_body.sh} $installer
      ${gnused}/bin/sed -i -e "s/%%IMAGE_SHA1%%/$sha1/" $installer
      chmod a+wx $installer

      echo "Creating installer"
      cat payload.tar >> $installer
      echo ${component} >$out/component
      echo ${version} >$out/version
      rm payload.tar
    '';
  } (''
    chroot=/chroot
    mkdir $chroot

    exec_chroot () {
      chroot $chroot /bin/env PATH=/bin:/usr/bin:/sbin:/usr/sbin "$@"
    }

    debootstrap --unpack-tarball=${bootstrap.tarball} ${bootstrap.release} $chroot
    ${cpGrubDefaults}
    mount -t devtmpfs devtmpfs $chroot/dev
    mount -t devpts devpts $chroot/dev/pts
    ln -s /proc/self/fd $chroot/dev/fd
    exec_chroot apt-get clean
    exec_chroot /usr/sbin/update-initramfs -u
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

    if [ -s ${rootClosureInfo}/store-paths ]; then
      echo
      echo "Copying closure to chroot"
      rsync -a $(cat ${rootClosureInfo}/store-paths) $chroot/nix/store
      cat ${rootClosureInfo}/registration | exec_chroot /nix/var/nix/profiles/default/bin/nix-store --load-db
    fi
  '' +
   mkUsers +
   (lib.optionalString (postRootFsCreateCmd != null) ''
     cp ${postRootFsCreateCmd} $chroot/cmd
     exec_chroot /cmd
     rm $chroot/cmd
   '') +
   (lib.optionalString (postRootFsInstallCmd != null) ''
     cp ${postRootFsInstallCmd} $chroot/post-install-cmd
   '') +
  ''
    umount $chroot/dev/pts
    umount $chroot/dev
    umount $chroot/proc
    umount $chroot/sys

    tar -cf /tmp/xchg/rootfs.tar -C $chroot .
  '')
)
