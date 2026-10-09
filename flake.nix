{
  description = "nixos-core: shared NixOS modules and a machine template";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";

    # Noctalia v5 is the desktop shell. nixpkgs has only v4, so this
    # input builds v5 from its flake. The tag pin makes updates manual.
    noctalia = {
      url = "github:noctalia-dev/noctalia-shell?ref=v5.0.0-beta.10";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Obscura VPN's client is not in nixpkgs; its flake builds the daemon
    # and CLI from source (see modules/obscura.nix). The tag pin makes
    # updates manual. The rust-overlay revision the client pins predates
    # a nixpkgs change to fetchurl's default name and fails to unpack
    # the toolchain, so the client gets a current rust-overlay instead.
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    obscura = {
      url = "github:Sovereign-Engineering/obscuravpn-client?ref=v/1.182";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-overlay.follows = "rust-overlay";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      noctalia,
      obscura,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      # The library (see ./modules). The overlays make pkgs.noctalia
      # (modules/desktop.nix) and pkgs.obscura-cli (modules/obscura.nix)
      # available to the modules.
      nixosModules.default = {
        imports = [ ./modules ];
        nixpkgs.overlays = [
          noctalia.overlays.default
          (final: prev: {
            obscura-cli = obscura.packages.${final.stdenv.hostPlatform.system}.rust-cli-bin;
          })
        ];
      };

      # Scaffold for a new machine repo:
      #   nix flake init -t github:nullcopy/nixos-core#machine
      templates.machine = {
        path = ./templates/machine;
        description = "Per-machine NixOS flake consuming nixos-core";
      };

      formatter.${system} = pkgs.nixfmt;
    };
}
