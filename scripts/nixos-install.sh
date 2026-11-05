#!/usr/bin/env bash
set -euo pipefail

CORE="github:nullcopy/nixos-core" # the flake that provides the machine template

[[ $EUID -eq 0 ]] || {
  echo "Run as root."
  exit 1
}

# Prompts with readline editing; Tab completes paths at the disk and
# repo prompts. -e 7 hides loop devices.
echo "Disks:"
lsblk -dno PATH,SIZE,MODEL -e 7
while :; do
  read -e -r -p "Disk to erase and install to: " -i /dev/ DISK
  [[ -b "$DISK" && "$(lsblk -dno TYPE "$DISK")" == disk ]] && break
  echo "Not a whole disk: $DISK"
done
while :; do
  read -e -r -p "Hostname (networking.hostName and the nixosConfigurations.<name> attribute): " HOSTNAME
  [[ "$HOSTNAME" =~ ^[a-z0-9-]+$ ]] && break
  echo "Use lowercase letters, digits and hyphens."
done
while :; do
  read -e -r -p "Admin user (wheel group; owns the machine repo): " ADMINUSER
  [[ "$ADMINUSER" =~ ^[a-z_][a-z0-9_-]*$ ]] && break
  echo "Use a lowercase user name."
done
# Empty: scaffold a new machine repo from nixos-core's template. For a
# reinstall, name the machine's existing repo instead: anything `git
# clone` accepts, such as a directory on a USB stick or a git bundle.
read -e -r -p "Existing machine repo to clone (empty for a fresh scaffold): " MACHINE_REPO
SSH=false
if [[ -z "$MACHINE_REPO" ]]; then
  read -r -p "Enable ssh (key-only; keys go in ~/.ssh/authorized_keys)? [y/N] " reply
  if [[ "$reply" =~ ^[Yy] ]]; then
    SSH=true
  fi
fi

echo "!!! This will completely erase $DISK. Type YES (all capitals) to continue:"
read -r confirm
[[ "$confirm" == "YES" ]] || {
  echo "Aborted."
  exit 1
}

# Clean up a previous attempt: /mnt may be mounted and the LUKS mapping
# open, which makes wipefs fail with "device busy".
umount -R /mnt 2>/dev/null || true
cryptsetup close cryptroot 2>/dev/null || true

# Partition suffix: NVMe/eMMC devices use a 'p' separator. SATA/USB do not.
if [[ "$DISK" =~ nvme|mmcblk ]]; then
  PART="${DISK}p"
else
  PART="${DISK}"
fi
BOOT="${PART}1"
ROOT="${PART}2"

# Partition
wipefs -a "$DISK"
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:ESP "$DISK"
sgdisk -n 2:0:0 -t 2:8300 -c 2:root "$DISK"
udevadm settle

# Encrypt
echo "Creating encrypted partition..."
cryptsetup luksFormat --type luks2 --pbkdf argon2id "$ROOT"
echo "Unlocking encrypted partition..."
cryptsetup open "$ROOT" cryptroot

# Format
mkfs.fat -F 32 -n BOOT "$BOOT"
mkfs.btrfs -L nixos /dev/mapper/cryptroot

# Subvolumes
mount /dev/mapper/cryptroot /mnt
for sv in @ @home @nix @log @snapshots; do
  btrfs subvolume create /mnt/$sv
done
umount /mnt

# Mount
OPTS="noatime,compress=zstd:3,space_cache=v2"
mount -o subvol=@,$OPTS /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,nix,var/log,.snapshots,boot}
mount -o subvol=@home,$OPTS /dev/mapper/cryptroot /mnt/home
mount -o subvol=@nix,$OPTS /dev/mapper/cryptroot /mnt/nix
mount -o subvol=@log,$OPTS /dev/mapper/cryptroot /mnt/var/log
mount -o subvol=@snapshots,$OPTS /dev/mapper/cryptroot /mnt/.snapshots
# umask keeps the ESP private (bootctl warns about a world-readable
# random seed). nixos-generate-config copies the masks into
# hardware-configuration.nix.
mount -o umask=0077 "$BOOT" /mnt/boot

# The live ISO ships without git; take one from the ISO's nixpkgs.
PATH="$(dirname "$(nix-shell -p git --run 'command -v git')"):$PATH"
nix() { command nix --extra-experimental-features 'nix-command flakes' "$@"; }

# The machine repo goes to /etc/nixos, where nixos-rebuild looks by
# default. The admin owns it (chown below), so git and `nixos-rebuild
# switch --sudo` run as the admin.
TARGET="/mnt/etc/nixos"
mkdir -p "$(dirname "$TARGET")"

# Stage everything in the repo and commit when something changed, with
# an explicit identity (the live ISO has none) and without running the
# repo's hooks: these commits run as root, and a machine repo cloned
# from elsewhere could carry any .githooks/pre-commit. core.hooksPath is
# handed to the admin's own commits once the installer is finished.
commit() { # MESSAGE
  git -C "$TARGET" add -A
  [[ -z "$(git -C "$TARGET" status --porcelain)" ]] ||
    git -C "$TARGET" -c "user.name=$ADMINUSER" -c "user.email=$ADMINUSER@$HOSTNAME" \
      -c core.hooksPath=/dev/null commit -q -m "$1"
}

if [[ -n "$MACHINE_REPO" ]]; then
  git clone "$MACHINE_REPO" "$TARGET"
else
  # Scaffold from the template and fill in the placeholders. `nix flake
  # init` writes every file without its executable bit, and git ignores
  # a hook it cannot execute. The hook is enabled below, after the
  # installer's own commits.
  mkdir "$TARGET"
  (cd "$TARGET" && nix flake init -t "$CORE#machine")
  chmod +x "$TARGET/.githooks/pre-commit"
  sed -i "s/MYHOSTNAME/$HOSTNAME/g; s/MYADMIN/$ADMINUSER/g" \
    "$TARGET/flake.nix" "$TARGET/configuration.nix"
  sed -i "s/^\(\s*services\.openssh\.enable = \)false;/\1$SSH;/" \
    "$TARGET/configuration.nix"
  git -C "$TARGET" init -q -b main
  commit "Scaffold $HOSTNAME from the nixos-core machine template"
fi

nixos-generate-config --root /mnt --show-hardware-config \
  >"$TARGET/hardware-configuration.nix"
# Let TRIM through dm-crypt, so the weekly fstrim (base.nix) reaches
# the SSD. It shows which blocks are free, not what the others hold
# (docs/fde.md).
if grep -q 'boot\.initrd\.luks\.devices\."cryptroot"\.device' "$TARGET/hardware-configuration.nix" &&
  ! grep -q 'allowDiscards' "$TARGET/hardware-configuration.nix"; then
  sed -i '$i\
\
  boot.initrd.luks.devices."cryptroot".allowDiscards = true;' \
    "$TARGET/hardware-configuration.nix"
fi

# Lock the flake before the install: nixos-install hashes the repo
# directory, and a lock file created mid-install changes the hash
# ("NAR hash mismatch").
nix flake lock "path:$TARGET"
commit "Add hardware configuration and lock for $HOSTNAME"

echo
echo ">>> machine repo ready in $TARGET/: hardware-configuration.nix generated, flake.lock created, both committed"

# Advisory checks for the errors that otherwise appear late, inside
# nixos-install.
check() { # FILE REGEX DESCRIPTION
  if grep -qE "$2" "$1"; then
    echo ">>> ok:      $3"
  else
    echo ">>> WARNING: $3 -- not found in $(basename "$1")"
  fi
}
check "$TARGET/configuration.nix" "hostName *= *\"$HOSTNAME\"" \
  "configuration.nix sets networking.hostName = \"$HOSTNAME\""
check "$TARGET/flake.nix" "nixosConfigurations\.$HOSTNAME([^A-Za-z0-9_-]|$)" \
  "flake.nix defines nixosConfigurations.$HOSTNAME"
check "$TARGET/configuration.nix" "users\.users\.$ADMINUSER([^A-Za-z0-9_-]|$)" \
  "users.users.$ADMINUSER is declared in configuration.nix"

# A tunnel address as address/prefix, IPv4 or IPv6. The peer stanza below
# is built from it and the module hands it to the interface, so catch a
# typo at the prompt rather than later.
valid_cidr() { # ADDRESS/PREFIX
  local addr prefix octet
  [[ "$1" == */* ]] || return 1
  addr="${1%%/*}"
  prefix="${1#*/}"
  [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
  if [[ "$addr" == *:* ]]; then
    (( prefix <= 128 )) || return 1
    [[ "$addr" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
  else
    (( prefix <= 32 )) || return 1
    [[ "$addr" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    local IFS=.
    local -a octets
    read -r -a octets <<<"$addr"
    for octet in "${octets[@]}"; do
      (( octet <= 255 )) || return 1
    done
  fi
}

# Review shell: bash on /dev/tty, exit status ignored so a failure here
# survives set -e. A fresh scaffold has every core.* toggle off, so this
# is where configuration.nix gets its settings. Edits are committed.
echo
if [[ -z "$MACHINE_REPO" ]]; then
  echo ">>> The scaffold has every core.* toggle off. Open a shell in $TARGET"
  echo ">>> to edit configuration.nix before installing? [Y/n]"
else
  echo ">>> Open a shell in $TARGET to review or edit before installing? [Y/n]"
fi
read -r reply
if [[ ! "$reply" =~ ^[Nn] ]]; then
  echo ">>> Type 'exit' to continue the install."
  (cd "$TARGET" && bash -i </dev/tty >/dev/tty 2>&1) || true
  commit "Configure $HOSTNAME"
fi

# The WireGuard exit needs its client key on the target root before the
# first boot, and the relay needs the matching public key. Generate the
# key, fill in the tunnel address if the config leaves it out, and print
# the peer stanza for the relay's machine repo.
if grep -qE '^[[:space:]]*core\.wireguardExit\.enable[[:space:]]*=[[:space:]]*true' \
  "$TARGET/configuration.nix"; then
  IFACE="$(sed -n 's|^[[:space:]]*core\.wireguardExit\.interface[[:space:]]*=[[:space:]]*"\([^"]*\)".*|\1|p' \
    "$TARGET/configuration.nix" | head -n1)"
  IFACE="${IFACE:-wg0}"
  ADDR="$(sed -n 's|^[[:space:]]*core\.wireguardExit\.address[[:space:]]*=[[:space:]]*"\([^"]*\)".*|\1|p' \
    "$TARGET/configuration.nix" | head -n1)"
  if [[ -z "$ADDR" ]]; then
    # A hostname-derived default inside the tunnel subnet. The relay's
    # repo is the registry of these addresses, so change it there if the
    # number is taken.
    octet=$(( $(printf '%s' "$HOSTNAME" | cksum | cut -d' ' -f1) % 250 + 2 ))
    while :; do
      read -e -r -p "Tunnel address (core.wireguardExit.address): " -i "10.99.99.$octet/24" ADDR
      valid_cidr "$ADDR" && break
      echo "Use address/prefix, such as 10.99.99.$octet/24 or fd00::7/64."
    done
    sed -i "s|^\([[:space:]]*core\.wireguardExit\.enable[[:space:]]*=[[:space:]]*true;.*\)\$|\1\n  core.wireguardExit.address = \"$ADDR\";|" \
      "$TARGET/configuration.nix"
    commit "Set the WireGuard exit address for $HOSTNAME"
  elif ! valid_cidr "$ADDR"; then
    echo ">>> WARNING: core.wireguardExit.address is \"$ADDR\"; that is not"
    echo ">>> address/prefix, so the peer stanza below may be wrong."
  fi

  # wireguard-tools is not on the live ISO; take it from the ISO's
  # nixpkgs, as git above.
  PATH="$(dirname "$(nix-shell -p wireguard-tools --run 'command -v wg')"):$PATH"
  install -d -m 0755 /mnt/etc/wireguard
  (umask 077; wg genkey >"/mnt/etc/wireguard/$IFACE.key")
  chmod 0600 "/mnt/etc/wireguard/$IFACE.key"
  echo
  echo ">>> Wrote the client key to /mnt/etc/wireguard/$IFACE.key (root, 0600)."
  PUB="$(wg pubkey <"/mnt/etc/wireguard/$IFACE.key")"

  echo ">>> On the relay's machine repo, add this peer to the relay's own"
  echo ">>> networking.wireguard.interfaces.<relay interface>.peers and rebuild"
  echo ">>> the relay BEFORE this machine's first boot:"
  echo
  # A host route for the client: /32 for IPv4, /128 for IPv6.
  mask=32
  if [[ "$ADDR" == *:* ]]; then mask=128; fi
  echo "  { publicKey = \"$PUB\"; allowedIPs = [ \"${ADDR%%/*}/$mask\" ]; }"
  echo
  echo ">>> Until the relay knows this key, the exit gate holds and this"
  echo ">>> machine has no network egress. docs/vpn.md has both ends."
elif grep -q "core\.wireguardExit" "$TARGET/configuration.nix"; then
  echo
  echo ">>> WARNING: configuration.nix mentions core.wireguardExit without a"
  echo ">>> 'core.wireguardExit.enable = true;' line, so no client key was"
  echo ">>> generated and no peer stanza printed. If the module is enabled,"
  echo ">>> do it by hand before the first boot (docs/vpn.md):"
  echo ">>>   sudo wg genkey | sudo tee /etc/wireguard/wg0.key >/dev/null"
  echo ">>>   sudo chmod 600 /etc/wireguard/wg0.key && sudo wg pubkey < /etc/wireguard/wg0.key"
fi

# The installer is done committing; hand the formatter hook to the repo
# for the admin's later commits. No hook from the repo ran while this
# script ran as root.
git -C "$TARGET" config core.hooksPath .githooks

echo ">>> Proceed with nixos-install? Type YES (all capitals) to continue:"
read -r confirm
[[ "$confirm" == "YES" ]] || {
  echo "Aborted. Everything is still mounted under /mnt; re-run this script to start over."
  exit 1
}

# Install from the local flake. The path: URI avoids the git-clean check.
nixos-install --flake "path:$TARGET#$HOSTNAME" --no-root-password

echo ">>> Setting password for '$ADMINUSER':"
nixos-enter --root /mnt -- passwd "$ADMINUSER"

# The repo was written as root; hand it to the now-existing admin.
nixos-enter --root /mnt -- chown -R "$ADMINUSER:users" /etc/nixos

umount -R /mnt
cryptsetup close cryptroot

echo
echo ">>> NOTE:"
echo ">>> If you declared more than one user, log in as $ADMINUSER first"
echo ">>> and set the other passwords with 'passwd <user>'."
echo ">>>"
echo ">>> Install complete. Remove the installation media and reboot."
