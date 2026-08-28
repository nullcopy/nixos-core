# NixOS machine config

Per-machine NixOS flake, built on
[nixos-core](https://github.com/nullcopy/nixos-core). The full
walkthrough is in
[nixos-core/docs/new-machine.md](https://github.com/nullcopy/nixos-core/blob/main/docs/new-machine.md).

1. Replace `MYHOSTNAME` (in `flake.nix` and `configuration.nix`) and
   `MYADMIN` with this machine's hostname and admin user.
2. Set the `core.*` toggles and machine-specific config in
   `configuration.nix`.
   [nixos-wisp](https://github.com/nullcopy/nixos-wisp) is a complete
   real example.
3. Install with nixos-core's `scripts/nixos-install.sh`.

The install script activates the pre-commit format hook. On any other
clone, run `git config core.hooksPath .githooks` one time.
