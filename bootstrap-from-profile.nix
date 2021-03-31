### Re-create a debootstrap tarball as originally produced by
### "debootsrap --make-tarball" from a tarball with the .deb files
### removed and a Nix expression containing the download URLs of the
### .deb files.
###
### bootstrapProfile must be a derivation containing three files:
###
###   bootstrap.tar
###     The original tarball with all .deb files removed
###
###   pkgs.nix
###     A list of attribute Sets with attributes
###        url    Download URL of the .deb file
###        sha256 The sha256 hash of the file
###        name   The name of the file in the original
###               tarball
###   release.nix
###     The name of the Debian release as a string
###
### Profiles are created with the mk-profile.sh utility, which selects
### the packages to include for debootstrap.

{ lib, fetchurl, runCommand, bootstrapProfile }:

let
  release = import (bootstrapProfile + "/release.nix");
  specs = import (bootstrapProfile + "/pkgs.nix");
  fetch = spec: {
    pkg = fetchurl {
      inherit (spec) url sha256;
      ## Guard against illegal names derived from the URL
      name = "none";
    };
    ## This is the original name of the package in the tarball
    ## produced by debootstrap.
    inherit (spec) name;
  };
  debs = map fetch specs;
  cpDeb = deb: ''
    cp ${deb.pkg} var/cache/apt/archives/${deb.name}
  '';
  tarball = runCommand "${release}-bootstrap.tar" {} (''
    mkdir out
    cd out
    tar xf "${bootstrapProfile}/bootstrap.tar";
  '' + (lib.strings.concatStrings (map cpDeb debs)) + ''
    tar czf $out * 
  '');
in {
  inherit tarball release;
}
