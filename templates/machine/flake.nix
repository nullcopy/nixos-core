{
  description = "NixOS configuration for MYHOSTNAME";

  inputs = {
    # The shared library: modules, options, and baseline configuration.
    # Update it manually with:  nix flake update core
    core.url = "github:nullcopy/nixos-core";

    # Use the same nixpkgs revision as core.
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
      # The attribute name must be the hostname of this machine. Then
      # `nixos-rebuild switch --sudo` finds it automatically.
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
