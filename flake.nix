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
      # The library (see ./modules). The overlay makes pkgs.noctalia
      # available to the modules (see modules/desktop.nix).
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
