# WARNING: GENERATED FILE, DO NOT EDIT.
# This file is generated by running hack/bin/generate-local-nix-packages.sh and
# must be regenerated whenever local packages are added or removed, or
# dependencies are added or removed.
{ mkDerivation, base, base64-bytestring, bytestring
, gitignoreSource, imports, lib, libsodium
}:
mkDerivation {
  pname = "sodium-crypto-sign";
  version = "0.1.2";
  src = gitignoreSource ./.;
  libraryHaskellDepends = [
    base base64-bytestring bytestring imports
  ];
  libraryPkgconfigDepends = [ libsodium ];
  description = "FFI to some of the libsodium crypto_sign_* functions";
  license = lib.licenses.agpl3Only;
}