# NixOS machine config

Per-machine NixOS flake built on [nixos-core](https://github.com/nullcopy/nixos-core).

## Setting up

Full walkthrough:
[nixos-core/docs/new-machine.md](https://github.com/nullcopy/nixos-core/blob/main/docs/new-machine.md).
In short:

1. Replace every `MYHOSTNAME` (in `flake.nix` and `configuration.nix`) with this
   machine's hostname, and `MYADMIN` with the admin user's name.
2. Set the `core.*` toggles and any machine-specific config in `configuration.nix`
   ([nixos-wisp](https://github.com/nullcopy/nixos-wisp) is a complete real example).
3. Install with nixos-core's `scripts/nixos-install.sh`, which also generates
   `hardware-configuration.nix` for this machine.

## Day to day

```
sudo nixos-rebuild switch --flake ~/.nixos   # or wherever this repo is cloned
nix flake update core                       # pull in nixos-core improvements
nix flake update                            # bump everything (core + nixpkgs)
```

Users manage their own environments from their own dotfiles repos with
standalone home-manager; this repo only declares that their accounts exist.

Pre-commit formatting hook: the installer activates it in `~/.nixos`; on any
other clone run `git config core.hooksPath .githooks` once.
