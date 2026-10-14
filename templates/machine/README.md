# NixOS machine config

Per-machine NixOS flake, built on
[nixos-core](https://github.com/nullcopy/nixos-core). The full
walkthrough is in
[nixos-core/docs/new-machine.md](https://github.com/nullcopy/nixos-core/blob/main/docs/new-machine.md).

nixos-core's `scripts/nixos-install.sh` creates this repo at `/etc/nixos`
on the machine, owned by the admin user, with the hostname and the admin
user filled in, `hardware-configuration.nix` generated, and the
pre-commit format hook active. The repo lives on the machine only and
has no remote.

- `configuration.nix` — `core.*` toggles, accounts, machine-specific
  config
- `hardware-configuration.nix` — generated at install
- `flake.nix` — consumes nixos-core as `core`; `flake.lock` pins it
  (`nix flake update core`)

In a clone made some other way, run
`git config core.hooksPath .githooks` once.
