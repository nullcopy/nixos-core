#!/usr/bin/env bash
# Create the data pool "tank" in the layout docs/backup.md describes:
# pick the disks, pick the topology, wipe them, create the pool with
# the standard properties and tank/local with its own passphrase.
#
#   core-zpool [--root DIR] [--config FILE] [--pool NAME] [--no-local]
#
# Installed as `core-zpool` on machines with core.zfs.enable, and run
# by scripts/nixos-install.sh before the first install with
# --root /mnt. Root is where /etc/zfs/keys lives and where tank/local
# mounts (as an altroot) until the next boot. --config names a
# configuration.nix to update: core.zfs.enable, .pools and .unlock.
set -euo pipefail

ROOT=/
CONFIG=
POOL=tank
LOCAL=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT=$2; shift 2 ;;
    --config) CONFIG=$2; shift 2 ;;
    --pool) POOL=$2; shift 2 ;;
    --no-local) LOCAL=0; shift ;;
    -h | --help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
ROOT=${ROOT%/}
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

if zpool list -H -o name 2>/dev/null | grep -qx "$POOL"; then
  echo "pool $POOL is already imported on this machine; nothing to do" >&2
  exit 1
fi

# A stable name for zpool create: the first by-id link that is not a
# wwn or eui alias, so `zpool status` reads like the drive label.
by_id() { # /dev/sdX
  local link
  for link in /dev/disk/by-id/*; do
    [[ $link == */wwn-* || $link == */nvme-eui.* ]] && continue
    [[ $(readlink -f "$link") == "$1" ]] && { echo "$link"; return; }
  done
  echo "$1"
}

# Disks with anything mounted below them, or in an imported pool, are
# shown but cannot be chosen.
in_use() { # /dev/sdX
  lsblk -nro MOUNTPOINT "$1" | grep -q . && return 0
  zpool status -P 2>/dev/null | grep -q "$(readlink -f "$1")" && return 0
  local p
  for p in $(lsblk -nro PATH "$1"); do
    zpool status -P 2>/dev/null | grep -q "$(readlink -f "$p")" && return 0
  done
  return 1
}

mapfile -t DISKS < <(lsblk -dnro PATH,TYPE | awk '$2 == "disk" { print $1 }' | grep -v '^/dev/\(loop\|zram\|sr\)')
[[ ${#DISKS[@]} -gt 0 ]] || { echo "no disks found" >&2; exit 1; }

echo "Disks:"
declare -a USABLE
for i in "${!DISKS[@]}"; do
  d=${DISKS[$i]}
  info=$(lsblk -dnro SIZE,MODEL,SERIAL "$d" | tr -s ' ')
  if in_use "$d"; then
    printf '  %2d) %-14s %s   (in use)\n' "$((i + 1))" "$d" "$info"
  else
    printf '  %2d) %-14s %s\n' "$((i + 1))" "$d" "$info"
    USABLE[i]=1
  fi
done
[[ ${#USABLE[@]} -gt 0 ]] || { echo "every disk is in use" >&2; exit 1; }

echo
echo "Disks for pool $POOL, by number, separated by spaces (everything on them is erased):"
read -r -a picks
declare -a CHOSEN
for n in "${picks[@]}"; do
  [[ $n =~ ^[0-9]+$ ]] && [[ -n ${USABLE[$((n - 1))]:-} ]] || { echo "bad choice: $n" >&2; exit 1; }
  CHOSEN+=("${DISKS[$((n - 1))]}")
done
[[ ${#CHOSEN[@]} -gt 0 ]] || { echo "nothing chosen" >&2; exit 1; }
N=${#CHOSEN[@]}

echo
case $N in
  1)
    TOPOLOGY=single
    echo "One disk: no redundancy. A failed disk loses the pool; replication to a peer is the safety net."
    ;;
  *)
    echo "Topology for $N disks:"
    echo "  1) mirror   $N-way; any $((N - 1)) disks may fail; capacity of one disk"
    [[ $N -ge 3 ]] && echo "  2) raidz1   one disk may fail; capacity of $((N - 1)) disks"
    [[ $N -ge 4 ]] && echo "  3) raidz2   two disks may fail; capacity of $((N - 2)) disks"
    read -r t
    case "$t" in
      1) TOPOLOGY=mirror ;;
      2) if [[ $N -ge 3 ]]; then TOPOLOGY=raidz1; else echo "bad choice" >&2; exit 1; fi ;;
      3) if [[ $N -ge 4 ]]; then TOPOLOGY=raidz2; else echo "bad choice" >&2; exit 1; fi ;;
      *) echo "bad choice" >&2; exit 1 ;;
    esac
    ;;
esac

declare -a VDEVS
for d in "${CHOSEN[@]}"; do VDEVS+=("$(by_id "$d")"); done
[[ $TOPOLOGY == single ]] && SPEC=("${VDEVS[@]}") || SPEC=("$TOPOLOGY" "${VDEVS[@]}")

echo
echo "Plan:"
echo "  zpool create $POOL ${SPEC[*]}"
[[ $LOCAL -eq 1 ]] && echo "  $POOL/local  encrypted, mounted at /$POOL, key in $ROOT/etc/zfs/keys/$POOL-local"
echo
echo "!!! This erases: ${CHOSEN[*]}. Type YES (all capitals) to continue:"
read -r confirm
[[ $confirm == YES ]] || { echo "Aborted."; exit 1; }

for d in "${CHOSEN[@]}"; do
  for p in $(lsblk -nro PATH "$d" | tail -n +2); do
    zpool labelclear -f "$p" 2>/dev/null || true
  done
  zpool labelclear -f "$d" 2>/dev/null || true
  wipefs -a "$d" >/dev/null
  sgdisk --zap-all "$d" >/dev/null
done
udevadm settle

# Compression is for tank/local; received raw datasets carry their
# sender's blocks and ignore it. autotrim is harmless on spinning
# disks (ZFS skips devices without TRIM) and right for SSDs.
ALTROOT=()
[[ $ROOT != "" ]] && ALTROOT=(-R "$ROOT")
zpool create -f "${ALTROOT[@]}" \
  -o ashift=12 -o autotrim=on \
  -O mountpoint=none -O canmount=off \
  -O compression=zstd -O atime=off -O xattr=sa -O acltype=posixacl \
  "$POOL" "${SPEC[@]}"

if [[ $LOCAL -eq 1 ]]; then
  KEYDIR=$ROOT/etc/zfs/keys
  KEYFILE=$KEYDIR/$POOL-local
  install -d -m 700 "$KEYDIR"
  PASS=$(head -c 32 /dev/urandom | base64 | tr -d '\n=')
  # The key file does not exist yet at creation (ZFS would read it
  # from the file's path on *this* system, which is wrong under
  # --root), so the passphrase goes in on stdin and keylocation is
  # pointed at the file afterwards.
  printf '%s\n' "$PASS" | zfs create \
    -o mountpoint="/$POOL" \
    -o encryption=aes-256-gcm -o keyformat=passphrase -o keylocation=prompt \
    "$POOL/local"
  zfs set keylocation="file:///etc/zfs/keys/$POOL-local" "$POOL/local"
  (umask 077 && printf '%s\n' "$PASS" >"$KEYFILE")
fi

echo
zpool status "$POOL"
echo
if [[ $LOCAL -eq 1 ]]; then
  echo ">>> Passphrase of $POOL/local (also in $KEYFILE). Record it in a password"
  echo ">>> manager: a raw backup of $POOL/local is readable only with it."
  echo ">>>"
  echo ">>>     $PASS"
  echo
fi

LINES=(
  "core.zfs.enable = true;"
  "core.zfs.pools = [ \"$POOL\" ];"
)
[[ $LOCAL -eq 1 ]] && LINES+=("core.zfs.unlock = [ \"$POOL/local\" ];")

if [[ -n $CONFIG && -f $CONFIG ]]; then
  # enable = false -> true; pools/unlock added after the enable line
  # when absent. Anything else is left for the admin.
  sed -i 's/^\(\s*\)core\.zfs\.enable = false;/\1core.zfs.enable = true;/' "$CONFIG"
  grep -q 'core\.zfs\.enable = true;' "$CONFIG" \
    || sed -i "0,/^\(\s*\)core\./s//\1core.zfs.enable = true;\n\1core./" "$CONFIG"
  for line in "${LINES[@]:1}"; do
    key=${line%% =*}
    grep -q "^\s*${key//./\\.} = " "$CONFIG" \
      || sed -i "s|^\(\s*\)core\.zfs\.enable = true;|&\n\1$line|" "$CONFIG"
  done
  echo ">>> $CONFIG now has:"
  grep -n 'core\.zfs\.' "$CONFIG" | sed 's/^/    /'
else
  echo ">>> Add to configuration.nix:"
  printf '    %s\n' "${LINES[@]}"
fi
