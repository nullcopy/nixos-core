{
  description = "NixOS configuration for MYHOSTNAME";

  inputs = {
    # The shared library: modules, options, and baseline config.
    # Pull in improvements deliberately with:  nix flake update core
    core.url = "github:nullcopy/nixos-core";

    # Use the exact nixpkgs revision core was tested against.
    nixpkgs.follows = "core/nixpkgs";
  };

  outputs =
    {
      self,
      core,
      nixpkgs,
      ...
    }:
    {
      # The attribute name must match this machine's hostname, so
      # `sudo nixos-rebuild switch --flake ~/.nixos` finds it automatically.
      nixosConfigurations.MYHOSTNAME = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          core.nixosModules.default
          ./hardware-configuration.nix
          ./configuration.nix
        ];
      };
    };
}
