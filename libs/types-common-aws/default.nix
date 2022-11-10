# WARNING: GENERATED FILE, DO NOT EDIT.
# This file is generated by running hack/bin/generate-local-nix-packages.sh and
# must be regenerated whenever local packages are added or removed, or
# dependencies are added or removed.
{ mkDerivation
, amazonka
, amazonka-sqs
, base
, base64-bytestring
, exceptions
, gitignoreSource
, imports
, lens
, lib
, monad-control
, proto-lens
, resourcet
, safe
, tasty
, tasty-hunit
, text
, time
}:
mkDerivation {
  pname = "types-common-aws";
  version = "0.16.0";
  src = gitignoreSource ./.;
  libraryHaskellDepends = [
    amazonka
    amazonka-sqs
    base
    base64-bytestring
    exceptions
    imports
    lens
    monad-control
    proto-lens
    resourcet
    safe
    tasty
    tasty-hunit
    text
    time
  ];
  description = "Shared AWS type definitions";
  license = lib.licenses.agpl3Only;
}
