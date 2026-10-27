# shellcheck shell=bash
# Entering the new system. The host drives every step; each stage-2 step runs
# as a separate chroot call so failures can be retried individually.

_mnt() { # dest mount-args...
  local dst=$1; shift
  if [[ $DRYRUN != 1 ]] && mountpoint -q "$dst"; then return 0; fi
  run mount "$@" "$dst"
}

# DNS for the chroot. A one-off `cp /etc/resolv.conf` breaks in three ways:
# the live system's file can be a link to a stub (127.0.0.53) or into /run;
# the stage3's file can be a symlink into /run, which the /run bind mount then
# hides; and on Wi-Fi the servers can change after the copy. So: find a file
# with real upstream servers, replace any symlink in the target with a plain
# file, and refresh it before every chroot step.

# Print the path of a resolv.conf with usable nameservers.
dns_source() {
  local f
  for f in /run/systemd/resolve/resolv.conf /run/NetworkManager/no-stub-resolv.conf \
           /etc/resolv.conf /run/NetworkManager/resolv.conf; do
    [[ -r $f ]] || continue
    # Skip systemd-resolved's stub unless it's the only option left.
    if grep -qE '^nameserver[[:space:]]+[0-9a-fA-F.:]+' "$f" && ! grep -qE '^nameserver[[:space:]]+127\.0\.0\.53' "$f"; then
      echo "$f"; return 0
    fi
  done
  # A local resolver (127.0.0.53, dnsmasq) still works: the chroot shares the network.
  if grep -qE '^nameserver' /etc/resolv.conf 2>/dev/null; then echo /etc/resolv.conf; return 0; fi
  return 1
}

dns_install() {
  [[ $DRYRUN == 1 ]] && return 0
  local src dest=$TARGET/etc/resolv.conf
  src=$(dns_source) || { echo "No DNS servers found on the live system (/etc/resolv.conf has no nameserver lines)."; return 1; }
  if [[ -L $dest ]]; then
    # Remember the stage3's link (restored at the end) and use a plain file meanwhile.
    [[ -e $RUNDIR/resolv.conf.link ]] || readlink "$dest" >"$RUNDIR/resolv.conf.link"
    rm -f "$dest"
  fi
  install -m 0644 "$src" "$dest"
}

# Can the new system look up the mirror? Explain clearly if not.
dns_check() {
  [[ $DRYRUN == 1 ]] && return 0
  local host
  host=$(sed -E 's#^[a-z]+://([^/:]+).*#\1#' <<<"$G_MIRROR")
  if chroot "$TARGET" getent hosts "$host" >/dev/null 2>&1; then
    echo "DNS works inside the new system ($host resolves)."
    return 0
  fi
  echo "DNS lookups fail inside the new system: $host doesn't resolve."
  if getent hosts "$host" >/dev/null 2>&1; then
    echo "They work on the live system, using $(dns_source || echo /etc/resolv.conf):"
  else
    echo "They fail on the live system too, so the network or DNS has dropped. Live /etc/resolv.conf:"
  fi
  sed 's/^/  /' "$(dns_source || echo /etc/resolv.conf)" 2>/dev/null
  echo "Fix the network (or edit $TARGET/etc/resolv.conf) from a shell, then retry."
  return 1
}

chroot_prepare() {
  dns_install
  _mnt "$TARGET/proc" --types proc /proc
  # Boot entries (efibootmgr, uefi-mkconfig) need the firmware variables.
  if [[ -d /sys/firmware/efi && $DRYRUN != 1 ]] && ! mountpoint -q /sys/firmware/efi/efivars; then
    run mount -t efivarfs efivarfs /sys/firmware/efi/efivars || true
  fi
  _mnt "$TARGET/sys" --rbind /sys
  run mount --make-rslave "$TARGET/sys"
  _mnt "$TARGET/dev" --rbind /dev
  run mount --make-rslave "$TARGET/dev"
  _mnt "$TARGET/run" --bind /run
  run mount --make-slave "$TARGET/run"
  # Stage-2 scripts live in /run/toboggan/bin, visible inside the chroot via /run.
  mkdir -p "$RUNDIR/bin"
  cp "$TOBOGGAN_DIR/chroot/stage2.sh" "$TOBOGGAN_DIR/chroot/use-fix.py" "$RUNDIR/bin/"
  chmod 755 "$RUNDIR/bin/"*
  dns_check
  echo "Chroot ready."
}

chroot_exec() {
  # Refresh DNS each step: on Wi-Fi the servers can change mid-install.
  dns_install >/dev/null 2>&1 || true
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
  perf_restore
  # Put back the stage3's resolv.conf symlink, if it had one.
  if [[ -s $RUNDIR/resolv.conf.link ]]; then
    rm -f "$TARGET/etc/resolv.conf"
    ln -s "$(cat "$RUNDIR/resolv.conf.link")" "$TARGET/etc/resolv.conf"
  fi
  disk_unmount_all
}