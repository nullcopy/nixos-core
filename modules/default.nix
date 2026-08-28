# Entry point: machine flakes import this as `core.nixosModules.default`.
# base.nix is always active; the other modules activate via their
# `core.*` options.
{
  imports = [
    ./base.nix
    ./desktop.nix
    ./fde.nix
    ./tailscale.nix
    ./nymvpn.nix
  ];
}
