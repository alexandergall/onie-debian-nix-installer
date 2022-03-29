# onie-debian-nix-installer

A Nix function to create an ONIE installer for a system containing the
Nix package manager on top of a Debian release. Optionally, the
closure of a list of store paths can be added to the Nix store.

## Usage

Create a profile with `mk-profile.sh`. The script takes the name of a
Debian release and an optional list of packages to add to the standard
list of packages to be installed in the ONIE image. For example (this
assumes that `debootstrap` is available on the system)

```
$ mk-profile.sh buster git make
```

The standard list of packages includes whatever `debootstrap` selects
by default and a set of packages added by `mk-profile.sh` (see the
definition of the `default_packages` variable in the script).

The script produces three files as output

   * `bootstrap.tar`. This is a tarball as produced by the
     `--make-tarball` option of `debootstrap` but with all `.deb`
     files removed.
   * `pkgs.nix`. A file containing a Nix expression that evaluates to
     a list with one entry per original `.deb` file. Each entry
     contains the URL from where the `.deb` file can be downloaded,
     the `sha256` hash and original Name of the Debian package.
   * `release`. A Nix expression that evaluates to a string containing
     the Debian release with which `mk-profile.sh` was called.

The original URL used by `debootstrap` points to the regular Debian
site `deb.debian.org`. This is a problem if the current stable release
is used to create the profile, because `.deb` files can change as the
stable release progresses through its update cycle.  As a consequence,
building the ONIE installer at a later time can fail.  For this
reason, the URLs are replaced by ones relative to
`snapshot.debian.org`, which contains an archive of all `.deb` files
ever created.  These URLs are stable over time and should allow for
builds of the ONIE installer at any point in the future.

The three files produced by `mk-profile.sh` need to be copied to the
project that wants to create an ONIE installer.  Within that project's
Nix expression, import this repository and call the resulting function
to build the installer

```Nix
  ## pkgs is an instance of a Nix package collection
  mkOnieInstaller = pkgs.callPackage (pkgs.fetchgit {
    url = "https://github.com/alexandergall/onie-debian-nix-installer";
    rev = "2adc7d6";
    sha256 = "0l95r97knig3pyk0zmbijpk5lih30hn3azmngk2rdjm7ag9vm12p";
  }) {};
  onieInstaller = mkOnieInstaller { ... };
```
The function takes the following arguments

   * `bootstrapProfile`. **Mandatory**. A derivation that contains the
     three files generated by `mk-profile.sh`.
   * `rootPaths`. **Optional**. A list of derivations whose closure
     will be installed in the Nix store of the image. The default is
     an empty list.
   * `holdPackages`. **Optional**. A list of package names that will
     be marked to be held back from upgrading with `apt-mark
     hold`. The default is an empty list.
   * `postRootFsCreateCmd`. **Optional**. A command that is executed
     after the root file system is created (including installation of
     Nix). The command is executed in a `chroot` environment of the
     root file system. `postRootFsCreateCmd` must be a derivation that
     evaluates to a single executable in the Nix store.  The default
     is `null` which disables the feature.
   * `postRootFsInstallCmd`. **Optional**. A command that is executed
     after the root file system has been installed on the installation
     target during the ONIE installation. The command is executed in a
     `chroot` environment of the root file system.  At that stage, the
     install target's platform type is available from the file
     `/etc/machine.conf` in the `chroot` environment. The file is a
     copy of `machine.conf` from the ONIE install partition. It can be
     sourced as a shell script, which makes the platform available as
     the `onie_machine` variable.  `postRootFsInstallCmd` must be a
     derivation that evaluates to a single executable in the Nix
     store.  The default is `null` which disable the feature.
   * `binaryCaches`. **Optional**. A list of binary caches to add to
     the Nix configuration `/etc/nix/nix.conf` in addition to the
     standard Nix binary cache. Each item in the list must be a set
     with keys
     * `url`. The URL of the cache as expected by the
       `extra-substituters` and `trusted-substituters` option of
       `nix.conf`.
     * `key`. The public key of the cache as expected by the
       `trusted-public-keys` option of `nix.conf`.
     The default is an empty list.
   * `fileTree`. **Optional**. A derivation containing a directory
     tree which will be copied onto the root file system of the image
     after `debootstrap` is executed. The default is an empty tree.
     The tree may contain the top-level directory `__platforms` that
     contains subdirectories named after valid ONIE machine
     identifiers (e.g. `accton_wedge100bf_32x`) to support
     platform-specific file trees. When an image is installed on a
     target system, the installer checks for the presence of
     `/__platforms/<onie-machine>`. If it exists, its contents is
     copied to `/`. The directory `/__platforms` is deleted at the end
     of the installation in any case.
   * `rootPassword`. **Optional**. The root password in clear
     text. Root logins are only allowed on the serial console when the
     image boots for the first time. The default is an empty string.
   * `users`. **Optional**. An attribute set of user accounts to
     create. The names of the attributes are the names of the accounts
     and their values are sets of the form
	 ```
	 {
	   password = "..."; # optional, default none
	   useraddArgs = "..."; # optional, default ""
	   sshPublicKey = "..."; # optional, default ""
	   sudo = true | false; # optional, default true
	   passwordlessSudo = true | false; #optional, default true
     }
	 ```
	 The accounts are created right before the
     `postRootFsCreateCmd`. The account is created inside the chroot
     with
	 ```
	 useradd ${useraddArgs} ${user}
	 ```
	 If the `password` attribute exists, it's value is set as the
     user's password, otherwise the password is disabled.
	 If `sshPublicKey` is a non-empty string, it is copied to
     `/home/${user}/.ssh/authorized_keys`. If `sudo` is `true`, the
     string `${user} ALL=(ALL:ALL) ALL` is written to
     `/etc/sudoers.d/${user}`. If `passwordlessSudo` is `true`, the
     `NOPASSWD:` attribute is added as well.
   * `installerName`. **Optional**. The name of the final ONIE
     installer executable. The default is `onie-installer.bin`.
   * `NOS`. **Optional**. The name of the "Network Operating System"
     (in ONIE terminology). This name is used in the partition label
     of the Debian root partition and informational messages issued
     during the install. The default is the string `NOS`.
   * `grubDefault`. **Optional**. An attribute set of store paths that
     consist of a single file in the format required by
     `/etc/default/grub`. If the attribute `default` does not exist,
     it is added with the value

	```
     GRUB_DEFAULT=0
     GRUB_TIMEOUT=5
     GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0"
     GRUB_CMDLINE_LINUX=""
     GRUB_TERMINAL="console"
     ```

	 The file associated with the `default` attribute is copied to
     `/etc/default/grub`. All other files are installed as
     `/etc/default/grub-plaforms/<attribute-name>`.  At install time,
     it is checked whether the file
     `/etc/default/grub-plaforms/<onie_machine>` exists. If so, it is
     copied to `/etc/default/grub`, then `/etc/default/grub-platforms`
     is deleted. This implies that the attributes in this set are
     valid ONIE machine identifiers.

     Note that if `fileTree` also contains a file `/etc/default/grub`,
     it will take precedence.
   * `component`. **Optional**. An arbitrary string that will be
     written to a file named `component` in the derivation produced by
     this function. It can be used by the Hydra CI system to perform
     some action in the `post-build-hook` (e.g. copy it to a location
     where it can be made available for download). The default is an
     empty string.
   * `version`. **Optional**. An arbitrary string conveying version
     information about the service provided by `rootPaths`. It is
     written to a file named `version` in the derivation produced by
     this function. The purpose is the same as that of
     `component`. The default is an empty string.
   * `memSize`. The amount of memory to allocate for the VM in MiB.
     The default is 4096.

The installer is built in a VM, i.e. the build host must provide the
`kvm` feature. The build proceeds as follows:

   * Use `bootstrap-from-profile.nix` to re-create the original
     `debootstrap` tarball from `boootstrapProfile`.
   * Create an empty directory for the root file system and use it as
     a chroot for all following actions.
   * Call `debootstrap` to create the base root file system
   * Set `localhost` as host name.
   * Create `/etc/default/grub` and `/etc/default/grub-platforms` from
     `grubDefault`
   * Copy `fileTree` to the root file system. This can overwrite the
     host name and set the time zone and locale if desired, for
     example. If `/__platforms/<onie-machine>` exists, its contents is
     copied to `/`. The directory `/__platforms` is deleted at the end
     of the installation in any case.
   * Set the root password to `rootPassword`
   * Install Nix in multi-user mode. The installer is called with the
     options
        * `--no-channel-add`
        * `--no-modify-profile`
        * `--daemon-user-count 12`
   * Add binary caches
   * Create user accounts from the `users` argument.
   * If `rootPaths` is not an empty list, copy the closure of
     `rootPaths` to the Nix store.
   * If `postRootFsCreateCmd` is not `null`, execute it in the
     `chroot` environment of the root file system.
   * If `postRootFsInstallCmd` is not `null`, copy it to the
     root file system as `/post-install-cmd`.

The final root file system is then archived and compressed with
`xz`. The installer is created as a self-extracting archive using the
conventions expected by ONIE.

The installer can be executed on a target booted into ONIE "install
mode" with

```
ONIE# onie-nos-install <FILE|URL>
```

The installer performs the following steps:

   * Select the block device on which ONIE is installed as
     installation target
   * Estimate the required disk space by adding 20% to the size of the
     root file system and compare it with the maximum size of a
     partition that can be created on the block device.  The
     installation is aborted if the space requirement is not met. In
     this case, the existing disk layout is not changed.
   * Delete all partitions except the first two (the EFI boot loader
     and the ONIE installer)
   * Create partition #3 as the new root file system and use all of
     the remaining space on the install target for it
   * Format the partition with Ext3
   * Unpack the root file system onto partition #3
   * The `tar` command supplied by the ONIE installer does not
     preserve modification time stamps, which corrupts `/nix/store`.
     This is fixed by resetting all time stamps to epoch 0
   * If an executable `/post-install-cmd` exists, execute it in a
     `chroot` environment of the root file system, then delete the
     file. The main purpose of this step is to allow for
     platform-dependent configurations.
   * Install GRUB and add a boot menu entry to chain-load the ONIE
     installer
   * Set the EFI boot order to prefer booting from the new partition
   * Reboot into the new system

The Debian system can be upgraded at will, including new kernels and
modifications to the GRUB boot loader.
