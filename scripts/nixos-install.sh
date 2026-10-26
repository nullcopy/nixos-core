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
# an explicit identity (the live ISO has none).
commit() { # MESSAGE
  git -C "$TARGET" add -A
  [[ -z "$(git -C "$TARGET" status --porcelain)" ]] ||
    git -C "$TARGET" -c "user.name=$ADMINUSER" -c "user.email=$ADMINUSER@$HOSTNAME" \
      commit -q -m "$1"
}

if [[ -n "$MACHINE_REPO" ]]; then
  git clone "$MACHINE_REPO" "$TARGET"
  git -C "$TARGET" config core.hooksPath .githooks
else
  # Scaffold from the template and fill in the placeholders. `nix flake
  # init` writes every file without its executable bit, and git ignores
  # a hook it cannot execute. The hook path is set before the first
  # commit so the nixfmt pre-commit hook covers every commit.
  mkdir "$TARGET"
  (cd "$TARGET" && nix flake init -t "$CORE#machine")
  chmod +x "$TARGET/.githooks/pre-commit"
  sed -i "s/MYHOSTNAME/$HOSTNAME/g; s/MYADMIN/$ADMINUSER/g" \
    "$TARGET/flake.nix" "$TARGET/configuration.nix"
  sed -i "s/^\(\s*services\.openssh\.enable = \)false;/\1$SSH;/" \
    "$TARGET/configuration.nix"
  git -C "$TARGET" init -q -b main
  git -C "$TARGET" config core.hooksPath .githooks
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
