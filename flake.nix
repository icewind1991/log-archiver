{
  inputs = {
    nixpkgs.url = "nixpkgs/release-23.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        overlays = [
          (import ./overlay.nix)
        ];
        pkgs = import nixpkgs {
          inherit system overlays;
        };
      in rec {
        packages = rec {
          inherit (pkgs) log-archiver;
          default = log-archiver;
        };

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            rustc
            cargo
            bacon
            clippy
            cargo-edit
            cargo-outdated
            cargo-insta
            sqlx-cli
          ];
        };
      }
    )
    // {
      overlays.default = import ./overlay.nix;
      nixosModules.default = {
        pkgs,
        config,
        lib,
        ...
      }: {
        imports = [./module.nix];
        config = lib.mkIf config.services.log-archiver.enable {
          nixpkgs.overlays = [self.overlays.default];
          services.log-archiver.package = lib.mkDefault pkgs.log-archiver;
        };
      };
    };
}
