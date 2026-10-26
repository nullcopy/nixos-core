#!/usr/bin/env bash
# core-zpool: create a ZFS data pool on attached drives, in the layout
# docs/zfs.md describes. Pick the disks and the topology; the disks
# are wiped, the pool is created with the standard properties, and
# <pool>/encrypted is created as an encryption root with a generated
# passphrase. The core.zfs lines go into configuration.nix.
set -euo pipefail

CONFIG=/etc/nixos/configuration.nix
POOL=tank
ENCRYPTED=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG=${2:?--config needs a file}; shift 2 ;;
    --no-config) CONFIG=; shift ;;
    --pool) POOL=${2:?--pool needs a name}; shift 2 ;;
    --no-encrypted) ENCRYPTED=0; shift ;;
    -h | --help)
      cat <<'USAGE'
core-zpool [--config FILE | --no-config] [--pool NAME] [--no-encrypted]

Create a ZFS data pool on attached drives (docs/zfs.md in nixos-core):
pick disks and topology, wipe them, create the pool with the standard
properties and <pool>/encrypted as an encryption root with its own
passphrase, and add the core.zfs lines to configuration.nix.
  --config FILE   configuration.nix to update (default
                  /etc/nixos/configuration.nix)
  --no-config     only print the lines to add
  --pool NAME     pool name (default tank)
  --no-encrypted  no <pool>/encrypted dataset
USAGE
      exit 0
      ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() {
  echo "core-zpool: $*" >&2
  exit 1
}

[[ $EUID -eq 0 ]] || die "run as root"
[[ $POOL =~ ^[a-zA-Z][a-zA-Z0-9_.-]*$ ]] || die "bad pool name: $POOL"
# Names zpool create rejects, checked here so nothing is wiped first.
if [[ $POOL =~ ^(mirror|raidz|draid|spare) || $POOL == log || $POOL =~ ^c[0-9] ]]; then
  die "reserved pool name: $POOL"
fi
zpool list -H -o name 2>/dev/null | grep -qxF "$POOL" && die "pool $POOL is already imported"
# A second pool of the same name on another disk makes `zpool import
# <name>` at boot ambiguous, and neither pool is imported.
if zpool import 2>/dev/null | awk '$1 == "pool:" { print $2 }' | grep -qxF "$POOL"; then
  die "a pool named $POOL is on an attached disk (see zpool import); pick another --pool, or zpool labelclear its disks"
fi
KEYFILE=/etc/zfs/keys/$POOL-encrypted
if [[ $ENCRYPTED -eq 1 && -e $KEYFILE ]]; then
  die "$KEYFILE exists (the key of an earlier $POOL?); move it away or pick another --pool"
fi

# Whether configuration.nix can be edited is settled before anything is
# wiped: the file must exist and enable core.zfs on exactly one line of
# its own (the lines are added after it). Otherwise the lines are
# printed.
EDIT=0
if [[ -n $CONFIG ]]; then
  [[ -f $CONFIG ]] || die "$CONFIG does not exist (--config FILE, or --no-config)"
  case $(grep -c '^\s*core\.zfs\.enable = true;' "$CONFIG") in
    1) EDIT=1 ;;
    0) echo "core-zpool: $CONFIG has no 'core.zfs.enable = true;' line; the lines to add are printed at the end" >&2 ;;
    *) echo "core-zpool: $CONFIG has more than one 'core.zfs.enable = true;' line; the lines to add are printed at the end" >&2 ;;
  esac
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

# A disk is in use if it or any partition on it is mounted (or active
# swap), a member of an imported pool, held by another block device
# (an open LUKS container, an active LVM volume, an assembled md
# array), or a btrfs member whose filesystem is mounted through another
# device. Stale signatures of things that are not active do not count:
# those disks are what this wipes. `zpool status -LP` resolves the
# stored by-id links to the kernel names lsblk prints.
POOL_DEVICES=$(zpool status -LP 2>/dev/null | awk '$1 ~ /^\/dev\// { print $1 }' || true)
MOUNTED_UUIDS=$(lsblk -nro UUID,MOUNTPOINT | awk 'NF == 2 { print $1 }' || true)
in_use() { # /dev/sdX
  local p name uuid
  for p in $(lsblk -nro PATH "$1"); do
    [[ -n $(lsblk -dnro MOUNTPOINT "$p") ]] && return 0
    grep -qxF "$(readlink -f "$p")" <<<"$POOL_DEVICES" && return 0
    name=$(basename "$(readlink -f "$p")")
    compgen -G "/sys/class/block/$name/holders/*" >/dev/null && return 0
    if [[ $(lsblk -dnro FSTYPE "$p") == btrfs ]]; then
      uuid=$(lsblk -dnro UUID "$p")
      [[ -n $uuid ]] && grep -qxF "$uuid" <<<"$MOUNTED_UUIDS" && return 0
    fi
  done
  return 1
}

mapfile -t DISKS < <(lsblk -dnro PATH,TYPE | awk '$2 == "disk" { print $1 }' | grep -v '^/dev/\(loop\|zram\|sr\)')
[[ ${#DISKS[@]} -gt 0 ]] || die "no disks found"

echo "Disks:"
declare -A USABLE=()
for i in "${!DISKS[@]}"; do
  d=${DISKS[$i]}
  info=$(lsblk -dnro SIZE,MODEL,SERIAL "$d" | tr -s ' ')
  if in_use "$d"; then
    printf '  %2d) %-14s %s   (in use)\n' "$((i + 1))" "$d" "$info"
  else
    printf '  %2d) %-14s %s\n' "$((i + 1))" "$d" "$info"
    USABLE[$((i + 1))]=1
  fi
done
[[ ${#USABLE[@]} -gt 0 ]] || die "every disk is in use"

echo
echo "Disks for pool $POOL, by number, separated by spaces (everything on them is erased):"
read -r -a picks
declare -a CHOSEN=()
declare -A SEEN=()
for n in "${picks[@]}"; do
  if ! [[ $n =~ ^[1-9][0-9]*$ ]] || ((n > ${#DISKS[@]})); then die "bad choice: $n"; fi
  [[ -n ${USABLE[$n]:-} ]] || die "disk $n is in use"
  [[ -z ${SEEN[$n]:-} ]] || die "disk $n chosen twice"
  SEEN[$n]=1
  CHOSEN+=("${DISKS[$((n - 1))]}")
done
[[ ${#CHOSEN[@]} -gt 0 ]] || die "nothing chosen"
N=${#CHOSEN[@]}

echo
case $N in
  1)
    TOPOLOGY=single
    echo "One disk: no redundancy. A failed disk loses the pool; replication to another machine is the safety net."
    ;;
  *)
    echo "Topology for $N disks:"
    echo "  1) mirror   $N-way; any $((N - 1)) disks may fail; capacity of one disk"
    [[ $N -ge 3 ]] && echo "  2) raidz1   one disk may fail; capacity of $((N - 1)) disks"
    [[ $N -ge 4 ]] && echo "  3) raidz2   two disks may fail; capacity of $((N - 2)) disks"
    read -r t
    case "$t" in
      1) TOPOLOGY=mirror ;;
      2) if [[ $N -ge 3 ]]; then TOPOLOGY=raidz1; else die "bad choice"; fi ;;
      3) if [[ $N -ge 4 ]]; then TOPOLOGY=raidz2; else die "bad choice"; fi ;;
      *) die "bad choice" ;;
    esac
    ;;
esac

declare -a VDEVS=()
for d in "${CHOSEN[@]}"; do VDEVS+=("$(by_id "$d")"); done
if [[ $TOPOLOGY == single ]]; then SPEC=("${VDEVS[@]}"); else SPEC=("$TOPOLOGY" "${VDEVS[@]}"); fi

echo
echo "Plan:"
echo "  zpool create $POOL ${SPEC[*]}"
[[ $ENCRYPTED -eq 1 ]] && echo "  $POOL/encrypted  encrypted, mounted at /$POOL, key in $KEYFILE"
echo
echo "!!! This erases: ${CHOSEN[*]}. Type YES (all capitals) to continue:"
read -r confirm
[[ $confirm == YES ]] || die "aborted"

for d in "${CHOSEN[@]}"; do
  for p in $(lsblk -nro PATH "$d" | tail -n +2); do
    zpool labelclear -f "$p" 2>/dev/null || true
  done
  zpool labelclear -f "$d" 2>/dev/null || true
  wipefs -a "$d" >/dev/null
  sgdisk --zap-all "$d" >/dev/null
done
udevadm settle

# Compression is for <pool>/encrypted; raw-received datasets carry
# their sender's blocks and ignore it. autotrim is harmless on spinning
# disks (ZFS skips devices without TRIM) and right for SSDs.
zpool create -f \
  -o ashift=12 -o autotrim=on \
  -O mountpoint=none -O canmount=off \
  -O compression=zstd -O atime=off -O xattr=sa -O acltype=posixacl \
  "$POOL" "${SPEC[@]}"

print_passphrase() {
  echo ">>> Passphrase of $POOL/encrypted (also in $KEYFILE). Record it in a password"
  echo ">>> manager: a backup of $POOL/encrypted is readable only with it."
  echo ">>>"
  echo ">>>     $PASS"
}

if [[ $ENCRYPTED -eq 1 ]]; then
  # The key file is written before any zfs call that uses it, and the
  # passphrase is printed if anything after this point fails, so it
  # cannot end up only inside the dataset.
  PASS=$(head -c 32 /dev/urandom | base64 | tr -d '\n=')
  trap 'echo; echo "core-zpool: failed after the passphrase was made" >&2; print_passphrase >&2' ERR
  install -d -m 700 /etc/zfs/keys
  (umask 077 && printf '%s\n' "$PASS" >"$KEYFILE")
  zfs create \
    -o mountpoint="/$POOL" \
    -o encryption=aes-256-gcm -o keyformat=passphrase \
    -o keylocation="file://$KEYFILE" \
    "$POOL/encrypted"
fi

echo
zpool status "$POOL"
echo
if [[ $ENCRYPTED -eq 1 ]]; then
  print_passphrase
  echo
fi

LINES=("core.zfs.pools = [ \"$POOL\" ];")
[[ $ENCRYPTED -eq 1 ]] && LINES+=("core.zfs.unlock = [ \"$POOL/encrypted\" ];")

# Only the list itself (between `[` and `]` on the option's line) is
# read or changed, never a trailing comment.
list_re() { # OPTION
  printf '^([[:space:]]*%s = \\[)([^]]*)\\](.*)$' "${1//./\\.}"
}

# OPTION: the contents of each single-line list for OPTION.
list_items() {
  local re line
  re=$(list_re "$1")
  while IFS= read -r line; do
    [[ $line =~ $re ]] && printf '%s\n' "${BASH_REMATCH[2]}"
  done <"$CONFIG"
  return 0
}

list_has() { # OPTION VALUE
  list_items "$1" | grep -qF "\"$2\""
}

# OPTION VALUE: append VALUE to OPTION's single-line list, or add the
# option at the end of the core.zfs lines that follow the (one) enable
# line. A commented-out placeholder for the option is removed.
add_to_list() {
  local key=$1 value=$2 re i e n indent
  local -a lines items
  sed -i "/^\s*# ${key//./\\.} = /d" "$CONFIG"
  list_has "$key" "$value" && return 0
  mapfile -t lines <"$CONFIG"
  if grep -q "^\s*${key//./\\.} = \[" "$CONFIG"; then
    # A list spanning several lines, or set twice, is left alone.
    [[ $(list_items "$key" | wc -l) -eq 1 ]] || return 1
    re=$(list_re "$key")
    for i in "${!lines[@]}"; do
      if [[ ${lines[$i]} =~ $re ]]; then
        read -r -a items <<<"${BASH_REMATCH[2]}"
        items+=("\"$value\"")
        lines[i]="${BASH_REMATCH[1]} ${items[*]} ]${BASH_REMATCH[3]}"
      fi
    done
  else
    re='^([[:space:]]*)core\.zfs\.enable = true;'
    for i in "${!lines[@]}"; do
      [[ ${lines[$i]} =~ $re ]] && { e=$i; indent=${BASH_REMATCH[1]}; }
    done
    [[ -n ${e:-} ]] || return 1
    # Past the complete one-line core.zfs settings right after it, so
    # options land in the order they are added.
    re='^[[:space:]]*core\.zfs\.[A-Za-z]+ = [^#]*;[[:space:]]*(#.*)?$'
    n=$e
    while [[ ${lines[n + 1]:-} =~ $re ]]; do n=$((n + 1)); done
    lines=("${lines[@]:0:n+1}" "$indent$key = [ \"$value\" ];" "${lines[@]:n+1}")
  fi
  printf '%s\n' "${lines[@]}" >"$CONFIG"
}

ok=0
if [[ $EDIT -eq 1 ]]; then
  ok=1
  add_to_list core.zfs.pools "$POOL" || ok=0
  [[ $ENCRYPTED -eq 1 ]] && { add_to_list core.zfs.unlock "$POOL/encrypted" || ok=0; }
  # Check the result rather than trust the edit.
  list_has core.zfs.pools "$POOL" || ok=0
  if [[ $ENCRYPTED -eq 1 ]]; then
    list_has core.zfs.unlock "$POOL/encrypted" || ok=0
  fi
fi
if [[ $ok -eq 1 ]]; then
  echo ">>> $CONFIG now has:"
  grep -n '^\s*core\.zfs\.' "$CONFIG" | sed 's/^/    /'
  echo ">>> Rebuild (nixos-rebuild switch --sudo) so the pool is imported at boot."
else
  echo ">>> Add to configuration.nix, then rebuild, or the pool is not imported at boot:"
  printf '    %s\n' "${LINES[@]}"
fi
