#!/usr/bin/env bash
set -euo pipefail

### CONFIG ###
DISK=/dev/nvme0n1
MACHINE_REPO="https://github.com/nullcopy/nixos-myhostname" # this machine's flake repo (from the nixos-core template)
HOSTNAME="myhostname" # must match nixosConfigurations.<name> in the machine flake
ADMINUSER="myAdminUser"       # wheel-group user declared in the machine's configuration.nix
##############

[[ $EUID -eq 0 ]] || {
  echo "Run as root."
  exit 1
}
[[ -b "$DISK" ]] || {
  echo "Disk not found: $DISK"
  exit 1
}

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

# Clone the machine flake into the admin's home ($HOME keeps daily git
# work sudo-free) and write the hardware configuration into it.
# install -d 0700: git clone alone creates the home 0755.
TARGET="/mnt/home/$ADMINUSER/.nixos"
install -d -m 700 "$(dirname "$TARGET")"
nix-shell -p git --run "git clone '$MACHINE_REPO' '$TARGET'"
nixos-generate-config --root /mnt --show-hardware-config \
  >"$TARGET/hardware-configuration.nix"

# Lock the flake first: nixos-install hashes the repo directory, and a
# lock file created mid-install changes the hash ("NAR hash mismatch").
nix --extra-experimental-features 'nix-command flakes' flake lock "path:$TARGET"

# Commit both with an explicit identity (the live ISO has none) and
# activate the nixfmt pre-commit hook.
nix-shell -p git --run "
  git -C '$TARGET' config core.hooksPath .githooks &&
  git -C '$TARGET' add hardware-configuration.nix flake.lock &&
  git -C '$TARGET' -c user.name='$ADMINUSER' -c user.email='$ADMINUSER@$HOSTNAME' \
    commit -q -m 'Add hardware configuration and lock for $HOSTNAME'"

echo
echo ">>> hardware-configuration.nix generated, flake.lock created, both committed in $TARGET/"

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

# Optional review shell: bash on /dev/tty, exit status ignored so a
# failure here survives set -e.
echo
echo ">>> Open a shell in $TARGET to review or edit before installing? [y/N]"
read -r reply
if [[ "$reply" =~ ^[Yy] ]]; then
  echo ">>> Type 'exit' to continue the install."
  (cd "$TARGET" && bash -i </dev/tty >/dev/tty 2>&1) || true
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

# The clone ran as root; hand the home to the now-existing admin.
nixos-enter --root /mnt -- chown -R "$ADMINUSER:users" "/home/$ADMINUSER"

umount -R /mnt
cryptsetup close cryptroot

echo
echo ">>> NOTE:"
echo ">>> If you declared more than one user, log in as $ADMINUSER first"
echo ">>> and set the other passwords with 'passwd <user>'."
echo ">>>"
echo ">>> Install complete. Remove the installation media and reboot."
