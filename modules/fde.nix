{
  config,
  lib,
  pkgs,
  ...
}:

# Full-disk encryption policy: the assertion below fails the build
# unless the initrd unlocks a LUKS volume (core.fde.allowUnencrypted
# skips it for disposable VMs). Keyslots and token unlock: docs/fde.md.
let
  cfg = config.core.fde;

  # Volumes with a real .device. The fido2 block below itself creates a
  # boot.initrd.luks.devices entry for cfg.name; tryEval filters entries
  # without a device.
  realVolumes = lib.filter (
    n: (builtins.tryEval (builtins.seq config.boot.initrd.luks.devices.${n}.device true)).success
  ) (lib.attrNames config.boot.initrd.luks.devices);
in
{
  options.core.fde = {
    allowUnencrypted = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Skip the mandatory-FDE assertion (disposable VMs).
      '';
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "cryptroot";
      description = ''
        Mapper name of the root LUKS volume
        (boot.initrd.luks.devices.<name>). The install script creates
        "cryptroot"; core.fde.fido2.enable attaches the FIDO2 crypttab
        option to this volume.
      '';
    };

    fido2.enable = lib.mkEnableOption "FIDO2/YubiKey unlock of the root LUKS volume at boot (stage-1 systemd)";
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.allowUnencrypted || config.boot.initrd.luks.devices != { };
          message = ''
            core: full-disk encryption is mandatory, but no LUKS volume is
            configured for unlock at boot (boot.initrd.luks.devices is empty).
            Declare the root LUKS device — the generated
            hardware-configuration.nix usually does; otherwise set
            boot.initrd.luks.devices.<name>.device in configuration.nix.
            For a deliberately unencrypted throwaway system, set
            core.fde.allowUnencrypted = true.
          '';
        }
        {
          assertion = !cfg.fido2.enable || lib.elem cfg.name realVolumes;
          message = ''
            core.fde.fido2.enable is set, but no LUKS volume named
            "${cfg.name}" is declared (volumes with a device:
            ${lib.concatStringsSep ", " realVolumes}).
            Set core.fde.name to the mapper name your hardware configuration
            uses, so fido2-device=auto is attached to the real root volume.
          '';
        }
      ];
    }

    (lib.mkIf cfg.fido2.enable {
      # FIDO2 unlock requires the systemd initrd.
      boot.initrd.systemd.enable = true;
      boot.initrd.luks.devices.${cfg.name}.crypttabExtraOpts = [ "fido2-device=auto" ];
    })
  ];
}
