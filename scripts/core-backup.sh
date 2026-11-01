#!/usr/bin/env bash
# core-backup: pair machines for ZFS-native backups and manage the
# senders this machine accepts. docs/backup.md has the design.
#
# Receiver (core.backup.receive.enable), as root:
#   core-backup invite NAME [--quota SIZE] [--yes]
#   core-backup accept NAME KEY [--quota SIZE]
#   core-backup list
#   core-backup revoke NAME
# Sender (core.backup.send):
#   core-backup key
#   core-backup join CODE
set -euo pipefail

STATE=/var/lib/backup
PEERS=$STATE/recv
KEYS=$STATE/authorized_keys
DATASET=${CORE_BACKUP_DATASET:-tank/recv}
WORMHOLE_RECEIVE=${CORE_BACKUP_WORMHOLE_RECEIVE:-core-backup-wormhole-receive}
# Receive accounts get uids from this range, recorded per peer, so a
# recreated account keeps the uid its zfs delegation refers to.
UID_MIN=55000
UID_MAX=55999

# What a sender may do under its own dataset. receive:append (no
# `receive -F`), no rollback, no destroy, no hold: a sender adds
# snapshots and can neither remove what it sent before nor keep this
# machine from pruning it. The encryption properties are what a raw
# stream sets on the datasets it creates.
PERMISSIONS=receive:append,create,mount,userprop,canmount,mountpoint,compression,encryption,keyformat,keylocation,pbkdf2iters

die() {
  echo "core-backup: $*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
core-backup invite NAME [--quota SIZE] [--yes]   accept a sender, key sent over magic-wormhole
core-backup accept NAME KEY [--quota SIZE]       accept a sender, key given on the command line
core-backup list                                  accepted senders, quota, use, newest snapshot
core-backup revoke NAME                           stop accepting a sender; its backups stay
core-backup key                                   this machine's backup public key
core-backup join CODE                             send this machine's key to an invite
USAGE
}

need_root() { [[ $EUID -eq 0 ]] || die "run as root"; }

check_name() {
  [[ $1 =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || die "bad name '$1': use the sender's hostname"
}

# One public key, no options: the line has to start with the key type,
# so nothing like command="..." can ride along.
check_key() {
  local re='^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa) [A-Za-z0-9+/]+=* ?[^[:cntrl:]]*$'
  [[ $1 =~ $re ]] || die "not a single SSH public key line"
}

check_quota() {
  [[ $1 =~ ^(none|[0-9]+(\.[0-9]+)?[KMGTP]?)$ ]] || die "bad quota '$1' (e.g. 6T, 500G, none)"
}

ensure_parent() {
  zfs list -H -o name "$DATASET" >/dev/null 2>&1 ||
    zfs create -p -o mountpoint=none -o canmount=off "$DATASET"
}

alloc_uid() {
  local uid
  for ((uid = UID_MIN; uid <= UID_MAX; uid++)); do
    getent passwd "$uid" >/dev/null && continue
    cat "$PEERS"/*/uid 2>/dev/null | grep -qx "$uid" && continue
    echo "$uid"
    return
  done
  die "no free uid in $UID_MIN-$UID_MAX"
}

# The account: no home, no password, bash because syncoid needs a POSIX
# shell on this end. sshd reads its key from $KEYS, with `restrict`.
ensure_user() {
  local name=$1 user=recv-$1 uid
  uid=$(<"$PEERS/$name/uid")
  if ! getent passwd "$user" >/dev/null; then
    # No --system: with a uid in the 55000s useradd warns "greater than
    # SYS_UID_MAX" on every run; the uid is explicit anyway.
    useradd --uid "$uid" --gid nogroup --no-create-home \
      --home-dir /var/empty --shell /run/current-system/sw/bin/bash \
      --comment "core-backup: receives from $name" "$user"
    usermod --password '*' "$user"
  fi
}

write_keyfile() {
  local name=$1
  install -d -m 755 "$STATE" "$KEYS"
  printf 'restrict %s\n' "$(<"$PEERS/$name/key")" >"$KEYS/recv-$name.tmp"
  chmod 644 "$KEYS/recv-$name.tmp"
  mv "$KEYS/recv-$name.tmp" "$KEYS/recv-$name"
}

setup_peer() {
  local name=$1 ds=$DATASET/$1 user=recv-$1
  zfs list -H -o name "$ds" >/dev/null 2>&1 ||
    zfs create -o mountpoint=none -o canmount=off "$ds"
  zfs unallow -u "$user" "$ds" 2>/dev/null || true
  zfs allow -u "$user" "$PERMISSIONS" "$ds"
  zfs set quota="$(<"$PEERS/$name/quota")" "$ds"
}

peers() {
  local d
  for d in "$PEERS"/*/; do
    [[ -f $d/key ]] && basename "$d"
  done
  return 0
}

cmd_accept() {
  need_root
  [[ $# -ge 2 ]] || die "usage: core-backup accept NAME KEY [--quota SIZE]"
  local name=$1 key=$2 quota=none
  shift 2
  while [[ $# -gt 0 ]]; do
    case $1 in
      --quota) quota=${2:?--quota needs a size}; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  check_name "$name"
  check_key "$key"
  check_quota "$quota"
  [[ ! -e $PEERS/$name ]] || die "$name is already accepted; revoke it first"
  ensure_parent
  install -d -m 755 "$STATE"
  install -d -m 700 "$PEERS"
  local uid
  uid=$(alloc_uid)
  mkdir -m 700 "$PEERS/$name"
  printf '%s\n' "$key" >"$PEERS/$name/key"
  printf '%s\n' "$uid" >"$PEERS/$name/uid"
  printf '%s\n' "$quota" >"$PEERS/$name/quota"
  ensure_user "$name"
  write_keyfile "$name"
  setup_peer "$name"
  echo "accepted $name: it sends as recv-$name into $DATASET/$name (quota $quota)"
}

cmd_invite() {
  need_root
  [[ $# -ge 1 ]] || die "usage: core-backup invite NAME [--quota SIZE] [--yes]"
  local name=$1 quota=none yes=0
  shift
  while [[ $# -gt 0 ]]; do
    case $1 in
      --quota) quota=${2:?--quota needs a size}; shift 2 ;;
      --yes | -y) yes=1; shift ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  check_name "$name"
  check_quota "$quota"
  [[ ! -e $PEERS/$name ]] || die "$name is already accepted; revoke it first"
  local key
  key=$("$WORMHOLE_RECEIVE" "$name") || die "no key received"
  check_key "$key"
  echo "received: $(ssh-keygen -lf - <<<"$key")"
  if [[ $yes -eq 0 ]]; then
    local answer
    read -r -p "accept it as $name? [y/N] " answer
    [[ $answer =~ ^[Yy] ]] || die "not accepted"
  fi
  cmd_accept "$name" "$key" --quota "$quota"
}

cmd_list() {
  need_root
  local name ds used newest
  printf '%-20s %-8s %-8s %s\n' NAME QUOTA USED NEWEST
  for name in $(peers); do
    ds=$DATASET/$name
    used=$(zfs get -H -o value used "$ds" 2>/dev/null || echo -)
    newest=$(zfs list -H -p -o creation -t snapshot -r "$ds" 2>/dev/null | sort -n | tail -1)
    [[ -n $newest ]] && newest=$(date -d "@$newest" '+%F %R') || newest=never
    printf '%-20s %-8s %-8s %s\n' "$name" "$(<"$PEERS/$name/quota")" "$used" "$newest"
  done
}

cmd_revoke() {
  need_root
  [[ $# -eq 1 ]] || die "usage: core-backup revoke NAME"
  local name=$1
  check_name "$name"
  [[ -d $PEERS/$name ]] || die "$name is not accepted"
  rm -f "$KEYS/recv-$name"
  zfs unallow -u "recv-$name" "$DATASET/$name" 2>/dev/null || true
  pkill -u "recv-$name" 2>/dev/null || true
  userdel "recv-$name" 2>/dev/null || true
  rm -rf "${PEERS:?}/$name"
  echo "revoked $name; its backups stay in $DATASET/$name (zfs destroy -r to remove them)"
}

# At boot (backup-receive-setup.service): the parent dataset, then for
# every accepted peer its account, key file, dataset, delegation and
# quota, from the state in $PEERS.
cmd_setup() {
  need_root
  ensure_parent
  local name
  for name in $(peers); do
    ensure_user "$name"
    write_keyfile "$name"
    setup_peer "$name"
  done
}

# At activation: recreate accounts a rebuild of /etc/passwd dropped.
cmd_users() {
  need_root
  local name
  for name in $(peers); do
    ensure_user "$name"
  done
}

cmd_key() {
  [[ -r $STATE/key.pub ]] || die "no backup key yet; backup-keygen.service makes it at boot"
  cat "$STATE/key.pub"
}

cmd_join() {
  [[ $# -eq 1 ]] || die "usage: core-backup join CODE"
  [[ -r $STATE/key.pub ]] || die "no backup key yet; backup-keygen.service makes it at boot"
  # wormhole's -F is a directory of .pub files (it feeds the path to
  # os.listdir()), not a key file; passing $STATE picks the single .pub
  # deterministically. --yes only skips the "Really send?" prompt: if a
  # second .pub ever lands in $STATE, wormhole asks which key to send.
  exec wormhole ssh accept --yes -F "$STATE" "$1"
}

cmd=${1:-help}
[[ $# -gt 0 ]] && shift
case $cmd in
  invite) cmd_invite "$@" ;;
  accept) cmd_accept "$@" ;;
  list) cmd_list "$@" ;;
  revoke) cmd_revoke "$@" ;;
  setup) cmd_setup "$@" ;;
  users) cmd_users "$@" ;;
  key) cmd_key "$@" ;;
  join) cmd_join "$@" ;;
  help | -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
