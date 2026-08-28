# Entry point for the nixos-core library. Machine flakes import this as
# `core.nixosModules.default`. Every module below is either always-on
# baseline (base.nix, with lib.mkDefault everywhere so machines can
# override) or inert until the machine flips its `core.*` option.
{
  imports = [
    ./base.nix
    ./desktop.nix
    ./fde.nix
    ./tailscale.nix
    ./nymvpn.nix
  ];
}
