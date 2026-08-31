{
  description = "nixos-core: shared NixOS modules and a machine template";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";

    # Noctalia v5 (the desktop shell) isn't in nixpkgs yet (which has v4);
    # its flake builds it from source. Pinned to a tag — bump deliberately.
    noctalia = {
      url = "github:noctalia-dev/noctalia-shell?ref=v5.0.0-beta.10";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      noctalia,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      # The library. Machine flakes take nixos-core as an input and list this
      # in their modules; everything it provides is baseline-with-mkDefault or
      # gated behind a `core.*` option (see ./modules). The overlay rides
      # along so modules can use pkgs.noctalia (see modules/desktop.nix).
      nixosModules.default = {
        imports = [ ./modules ];
        nixpkgs.overlays = [ noctalia.overlays.default ];
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
