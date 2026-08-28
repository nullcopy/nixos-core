{
  description = "nixos-core: shared NixOS modules and a machine template";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      # The library. Machine flakes take nixos-core as an input and list this
      # in their modules; everything it provides is baseline-with-mkDefault or
      # gated behind a `core.*` option (see ./modules).
      nixosModules.default = ./modules;

      # Scaffold for a new machine repo:
      #   nix flake init -t github:nullcopy/nixos-core#machine
      templates.machine = {
        path = ./templates/machine;
        description = "Per-machine NixOS flake consuming nixos-core";
      };

      formatter.${system} = pkgs.nixfmt;
    };
}
