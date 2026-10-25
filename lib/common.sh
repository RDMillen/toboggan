# shellcheck shell=bash
# Common helpers: logging, command execution, persisted answers/state and secrets.
#
# Everything the installer knows lives in $RUNDIR (/run/toboggan on the live
# system). /run is bind-mounted into the chroot, so stage 2 reads the same
# files without anything installer-related (or secret) touching the new disk.

# shellcheck disable=SC2034 # used by the other libs
TOBOGGAN_VERSION="0.4.1"
TARGET=${TARGET:-/mnt/gentoo}
RUNDIR=${RUNDIR:-/run/toboggan}
SECRETS="$RUNDIR/secrets"
STATE="$RUNDIR/state.sh"
ANSWERS="$RUNDIR/answers.sh"
HWDIR="$RUNDIR/hw"
KDIR="$RUNDIR/kernel"
LOG=${LOG:-$RUNDIR/install.log}
DRYRUN=${DRYRUN:-0}
ASSUME_YES=${ASSUME_YES:-0}

log()  { printf '[%(%F %T)T] %s\n' -1 "$*" >>"$LOG"; }
msg()  { printf '\n==> %s\n' "$*"; log "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; log "WARNING: $*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; log "ERROR: $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Run a command that changes the system. In dry-run mode, print it instead.
run() {
  log "+ $*"
  if [[ $DRYRUN == 1 ]]; then
    printf '[dry-run]'; printf ' %q' "$@"; printf '\n'
    return 0
  fi
  "$@"
}

rundir_init() {
  local old; old=$(umask); umask 077
  mkdir -p "$RUNDIR" "$SECRETS" "$HWDIR" "$KDIR"
  : >>"$STATE"; : >>"$ANSWERS"; : >>"$LOG"
  umask "$old"
}

# answers.sh holds what the user chose; state.sh holds facts discovered while
# installing (partition paths, UUIDs). Both are plain `KEY=value` shell files.
_persist() {
  local file=$1 key=$2 val=$3
  [[ $key =~ ^G_[A-Z0-9_]+$ ]] || die "invalid setting name: $key"
  sed -i "/^${key}=/d" "$file"
  printf '%s=%q\n' "$key" "$val" >>"$file"
  printf -v "$key" '%s' "$val"
}
answer_set() { _persist "$ANSWERS" "$@"; }
state_set()  { _persist "$STATE" "$@"; }

load_state() {
  # shellcheck source=/dev/null
  source "$ANSWERS"
  # shellcheck source=/dev/null
  source "$STATE"
}

# Secrets never go in answers/state, never reach the target disk, and are
# only ever read from files (so they don't show up in `ps` or the log).
secret_set() {
  local old; old=$(umask); umask 077
  printf '%s' "$2" >"$SECRETS/$1"
  umask "$old"
}
secret_path() { printf '%s' "$SECRETS/$1"; }

# Write stdin to a path inside the target: `wfile /etc/foo [mode] <<EOF`
wfile() {
  local dest="$TARGET$1" mode=${2:-0644}
  mkdir -p "$(dirname "$dest")"
  cat >"$dest"
  chmod "$mode" "$dest"
  log "wrote $1"
}

# /dev/sda + 2 -> /dev/sda2, /dev/nvme0n1 + 2 -> /dev/nvme0n1p2
part_dev() {
  if [[ $1 =~ [0-9]$ ]]; then printf '%sp%s' "$1" "$2"; else printf '%s%s' "$1" "$2"; fi
}

# Is word $1 in the space-separated list $2?
has_word() { [[ " $2 " == *" $1 "* ]]; }
