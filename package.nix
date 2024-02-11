{
  stdenv,
  rustPlatform,
  lib,
}: let
  inherit (lib.sources) sourceByRegex;
  src = sourceByRegex ./. ["Cargo.*" "(src|tests|.sqlx)(/.*)?"];
in
  rustPlatform.buildRustPackage rec {
    pname = "log-archiver";
    version = "0.1.0";

    SQLX_OFFLINE = 1;

    inherit src;

    cargoLock = {
      lockFile = ./Cargo.lock;
    };
  }
