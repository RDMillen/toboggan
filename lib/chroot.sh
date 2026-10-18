# shellcheck shell=bash
# Entering the new system. The host drives every step; each stage-2 step runs
# as a separate chroot call so failures can be retried individually.

_mnt() { # dest mount-args...
  local dst=$1; shift
  if [[ $DRYRUN != 1 ]] && mountpoint -q "$dst"; then return 0; fi
  run mount "$@" "$dst"
}

chroot_prepare() {
  run cp --dereference /etc/resolv.conf "$TARGET/etc/"
  _mnt "$TARGET/proc" --types proc /proc
  _mnt "$TARGET/sys" --rbind /sys
  run mount --make-rslave "$TARGET/sys"
  _mnt "$TARGET/dev" --rbind /dev
  run mount --make-rslave "$TARGET/dev"
  _mnt "$TARGET/run" --bind /run
  run mount --make-slave "$TARGET/run"
  # Stage-2 scripts live in /run/toboggan/bin, visible inside the chroot via /run.
  mkdir -p "$RUNDIR/bin"
  cp "$TOBOGGAN_DIR/chroot/stage2.sh" "$RUNDIR/bin/"
  chmod 755 "$RUNDIR/bin/"*
  echo "Chroot ready."
}

chroot_exec() {
  run chroot "$TARGET" /usr/bin/env -i HOME=/root TERM="${TERM:-linux}" NOCOLOR=true \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    /bin/bash /run/toboggan/bin/stage2.sh "$@"
}

chroot_shell() {
  clear
  echo "Shell inside the new system ($TARGET). Type 'exit' to return to the installer."
  chroot "$TARGET" /bin/bash -l || true
}

cstep() { step "$2" chroot_exec "$1"; }

# Copy logs and the hardware report into the new system, then unmount.
finish() {
  local dest="$TARGET/var/log/toboggan"
  mkdir -p "$dest"
  cp "$LOG" "$RUNDIR/summary.txt" "$ANSWERS" "$dest/" 2>/dev/null || true
  cp -r "$HWDIR" "$dest/hw" 2>/dev/null || true
  if [[ -d $KDIR ]]; then cp -r "$KDIR" "$dest/kernel" 2>/dev/null || true; fi
  chmod -R go-rwx "$dest"
  disk_unmount_all
}
