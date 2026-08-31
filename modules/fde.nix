{
  config,
  lib,
  pkgs,
  ...
}:

# Full-disk encryption policy.
#
# FDE is MANDATORY: the assertion below fails the build unless the initrd
# unlocks at least one LUKS volume. The generated hardware config usually
# declares it; if not, declare boot.initrd.luks.devices.<name>.device in
# the machine config. core.fde.allowUnencrypted is the escape hatch for
# throwaway VMs and is deliberately discouraged.
#
# Keyslot management (passphrase / FIDO2 / any mix): docs/fde.md.
# Boot-time token unlock: core.fde.fido2.enable (options below).
let
  cfg = config.core.fde;

  # Volumes that actually have a .device. Merely mentioning a name (as the
  # fido2 block below does for cfg.name) creates an entry in
  # boot.initrd.luks.devices, so attrNames alone can't tell a real volume
  # from a typo; a missing .device throws, which tryEval turns into false.
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
        DISCOURAGED. Skip the mandatory-FDE assertion (for throwaway VMs
        and similar). Real machines should never set this.
      '';
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "cryptroot";
      description = ''
        Mapper name of the root LUKS volume (the <name> in
        boot.initrd.luks.devices.<name>, i.e. /dev/mapper/<name>).
        The install script creates "cryptroot"; a manually partitioned
        machine must set this to whatever its hardware config declares.
        Only used by core.fde.fido2.enable.
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
      # FIDO2 unlock needs the systemd-based initrd (the legacy scripted
      # initrd can't talk to tokens).
      boot.initrd.systemd.enable = true;
      boot.initrd.luks.devices.${cfg.name}.crypttabExtraOpts = [ "fido2-device=auto" ];
    })
  ];
}
