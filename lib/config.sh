# shellcheck shell=bash
# Settings: defaults, answers-file loading, validation and the summary screen.
# The same validation runs for interactive and unattended installs.

# Every G_* setting, so `set -u` never trips on an optional one.
config_defaults() {
  : "${G_DISK:=}" "${G_BOOTMODE:=$(hw_boot_mode)}" "${G_FS:=ext4}" "${G_LUKS:=no}"
  : "${G_SWAP:=zram}" "${G_SWAP_SIZE:=4}" "${G_INIT:=openrc}" "${G_DESKTOP:=none}"
  : "${G_VIDEO_CARDS:=}" "${G_KERNEL:=bin}" "${G_KCONFIG_BASE:=localmod}"
  : "${G_INITRAMFS:=dracut}" "${G_BOOTLOADER:=grub}" "${G_MARCH:=native}" "${G_BINPKG:=no}"
  : "${G_JOBS:=$(hw_default_jobs)}" "${G_MIRROR:=https://distfiles.gentoo.org}"
  : "${G_LOCALE:=en_US.UTF-8}" "${G_TIMEZONE:=UTC}" "${G_KEYMAP:=us}"
  : "${G_HOSTNAME:=gentoo}" "${G_USERNAME:=}" "${G_STAGE3_INSECURE:=no}"
  : "${G_WIFI_SSID:=}" "${G_WIFI_KEYMGMT:=}" "${G_WIFI_HIDDEN:=no}"
  # Facts discovered during the install (state.sh)
  : "${G_BOOT_PART:=}" "${G_ROOT_PART:=}" "${G_ROOT_DEV:=}" "${G_ROOT_UUID:=}" "${G_ROOT_PARTUUID:=}"
  : "${G_BOOT_UUID:=}" "${G_LUKS_UUID:=}" "${G_SWAPFILE:=}" "${G_PROFILE_SUFFIX:=}"
  : "${G_KERNEL_CMDLINE:=}" "${G_GRUB_CMDLINE:=}"
  return 0
}

# Values that follow from the choices rather than being asked for.
config_derive() {
  if [[ $G_BOOTMODE == bios ]]; then
    answer_set G_BOOT_FS ext4; answer_set G_BOOT_MNT /boot
  elif [[ $G_BOOTLOADER == efistub ]]; then
    answer_set G_BOOT_FS vfat; answer_set G_BOOT_MNT /efi
  else
    answer_set G_BOOT_FS vfat; answer_set G_BOOT_MNT /boot
  fi
  # NetworkManager whenever there's a desktop or any Wi-Fi hardware: dhcpcd
  # alone can't join a wireless network.
  if wifi_present; then answer_set G_WIFI_HW yes; else answer_set G_WIFI_HW no; fi
  if [[ $G_DESKTOP != none || $G_WIFI_HW == yes || -n $G_WIFI_SSID ]]; then
    answer_set G_NET networkmanager
  else
    answer_set G_NET dhcpcd
  fi
  # Persist every setting so stage 2 (inside the chroot) sees the same values.
  local v
  for v in $(compgen -v G_); do
    case $v in G_BOOT_PART|G_ROOT_*|G_BOOT_UUID|G_LUKS_UUID|G_SWAPFILE|G_PROFILE_SUFFIX|G_*CMDLINE) continue ;; esac
    answer_set "$v" "${!v}"
  done
}

# Answers files are shell syntax (see examples/answers.conf). Secrets may be
# given there for test VMs; they're moved to the secrets dir and unset.
config_load_answers() {
  [[ -r $1 ]] || die "Cannot read answers file: $1"
  # shellcheck source=/dev/null
  source "$1"
  local pair name var
  for pair in G_ROOT_PASSWORD:root_pass G_USER_PASSWORD:user_pass \
              G_LUKS_PASSPHRASE:luks_pass G_WIFI_PASSPHRASE:wifi_psk; do
    var=${pair%%:*}; name=${pair#*:}
    if [[ -n ${!var:-} ]]; then secret_set "$name" "${!var}"; unset "$var"; fi
  done
  if [[ -n ${G_WIFI_SSID:-} && -z ${G_WIFI_KEYMGMT:-} ]]; then
    if [[ -s $(secret_path wifi_psk) ]]; then G_WIFI_KEYMGMT=psk; else G_WIFI_KEYMGMT=none; fi
  fi
}

# Time zone names are checked for shape only here. The live medium's own
# zoneinfo can be incomplete; the real check runs in the new system (s_locale).
valid_tz() { [[ $1 =~ ^(UTC|[A-Z][A-Za-z_+-]*(/[A-Za-z0-9_+-]+){1,2})$ ]]; }

_in() { local v=$1 x; shift; for x; do [[ $v == "$x" ]] && return 0; done; return 1; }

# Prints one problem per line; returns 1 if there are any.
validate_config() {
  local e=()
  [[ -n $G_DISK ]] || e+=("No target disk (G_DISK) chosen.")
  if [[ -n $G_DISK && $DRYRUN != 1 && ! -b $G_DISK ]]; then e+=("$G_DISK is not a block device."); fi
  _in "$G_BOOTMODE" uefi bios                     || e+=("G_BOOTMODE must be uefi or bios.")
  _in "$G_FS" ext4 xfs btrfs                      || e+=("G_FS must be ext4, xfs or btrfs.")
  _in "$G_LUKS" yes no                            || e+=("G_LUKS must be yes or no.")
  _in "$G_SWAP" none file zram                    || e+=("G_SWAP must be none, file or zram.")
  _in "$G_INIT" openrc systemd                    || e+=("G_INIT must be openrc or systemd.")
  _in "$G_DESKTOP" none plasma gnome xfce sway hyprland i3 || e+=("Unknown desktop: $G_DESKTOP.")
  _in "$G_KERNEL" bin sources                     || e+=("G_KERNEL must be bin or sources.")
  _in "$G_KCONFIG_BASE" localmod defconfig        || e+=("G_KCONFIG_BASE must be localmod or defconfig.")
  _in "$G_INITRAMFS" dracut ugrd none             || e+=("G_INITRAMFS must be dracut, ugrd or none.")
  _in "$G_BOOTLOADER" grub systemd-boot efistub   || e+=("G_BOOTLOADER must be grub, systemd-boot or efistub.")
  _in "$G_MARCH" native x86-64-v3 x86-64          || e+=("G_MARCH must be native, x86-64-v3 or x86-64.")
  _in "$G_BINPKG" yes no                          || e+=("G_BINPKG must be yes or no.")
  [[ $G_JOBS =~ ^[1-9][0-9]*$ ]]                  || e+=("G_JOBS must be a positive number.")
  [[ $G_SWAP != file || $G_SWAP_SIZE =~ ^[1-9][0-9]*$ ]] || e+=("G_SWAP_SIZE must be a whole number of GiB.")

  if [[ $G_BOOTMODE == bios && $G_BOOTLOADER != grub ]]; then
    e+=("$G_BOOTLOADER needs UEFI; this machine booted in BIOS mode, so use grub."); fi
  if [[ $G_LUKS == yes && $G_INITRAMFS == none ]]; then
    e+=("LUKS needs an initramfs to unlock the root partition."); fi
  if [[ $G_KERNEL == bin && $G_INITRAMFS == none ]]; then
    e+=("gentoo-kernel-bin builds storage and filesystem drivers as modules, so it needs an initramfs."); fi
  if has_word nvidia "$G_VIDEO_CARDS" && has_word nouveau "$G_VIDEO_CARDS"; then
    e+=("Choose either the proprietary NVIDIA driver or nouveau, not both."); fi
  [[ $G_LOCALE =~ ^[a-z]{2,3}_[A-Z]{2}\.UTF-8$ ]] || e+=("Locale should look like en_GB.UTF-8.")
  if [[ -r $TOBOGGAN_DIR/data/locales.txt ]] && ! grep -q "^${G_LOCALE//./\\.}|" "$TOBOGGAN_DIR/data/locales.txt"; then
    e+=("$G_LOCALE isn't a supported locale (see data/locales.txt)."); fi
  if [[ -r $TOBOGGAN_DIR/data/keymaps.txt ]] && ! grep -q "^${G_KEYMAP}|" "$TOBOGGAN_DIR/data/keymaps.txt"; then
    e+=("Unknown keymap: $G_KEYMAP (see data/keymaps.txt)."); fi
  valid_tz "$G_TIMEZONE" || e+=("Time zone should look like Europe/London or UTC.")
  [[ $G_HOSTNAME =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]] || e+=("Hostname may only contain letters, digits and hyphens.")
  [[ $G_USERNAME =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || e+=("Username must be lowercase letters, digits, - or _.")
  if [[ -n $G_WIFI_SSID ]]; then
    _in "$G_WIFI_KEYMGMT" none psk sae || e+=("G_WIFI_KEYMGMT must be none, psk or sae.")
    if [[ $G_WIFI_KEYMGMT != none && ! -s $(secret_path wifi_psk) ]]; then e+=("No Wi-Fi password for \"$G_WIFI_SSID\"."); fi
  fi
  [[ -s $(secret_path root_pass) ]] || e+=("No root password set.")
  [[ -s $(secret_path user_pass) ]] || e+=("No password set for $G_USERNAME.")
  if [[ $G_LUKS == yes && ! -s $(secret_path luks_pass) ]]; then e+=("No LUKS passphrase set."); fi

  (( ${#e[@]} == 0 )) && return 0
  printf '%s\n' "${e[@]}"
  return 1
}

summary_text() {
  local swap=$G_SWAP kern=$G_KERNEL
  [[ $G_SWAP == file ]] && swap="file, ${G_SWAP_SIZE} GiB"
  case $G_KERNEL in
    bin)     kern="gentoo-kernel-bin (prebuilt)" ;;
    sources) kern="gentoo-sources, make menuconfig starting from $G_KCONFIG_BASE" ;;
  esac
  cat <<EOF
Disk:          $G_DISK   <-- ALL DATA ON IT WILL BE ERASED
Boot mode:     $G_BOOTMODE ($G_BOOT_FS mounted at $G_BOOT_MNT)
Root:          $G_FS$( [[ $G_FS == btrfs ]] && echo " (subvolumes @ and @home, zstd compression)" )
Encryption:    $( [[ $G_LUKS == yes ]] && echo "LUKS2 on the root partition" || echo none )
Swap:          $swap
Init system:   $G_INIT
Desktop/WM:    $G_DESKTOP
Graphics:      ${G_VIDEO_CARDS:-(none)}
Kernel:        $kern
Initramfs:     $G_INITRAMFS
Bootloader:    $G_BOOTLOADER
Compiler:      -march=$G_MARCH -O2 -pipe, $G_JOBS parallel jobs
Packages:      $( [[ $G_BINPKG == yes ]] && echo "binary packages where they match, the rest compiled" || echo "all compiled from source" )
Mirror:        $G_MIRROR
Locale:        $G_LOCALE, time zone $G_TIMEZONE, keymap $G_KEYMAP
Network:       $( [[ $G_NET == networkmanager ]] && echo NetworkManager || echo dhcpcd )$( [[ -n $G_WIFI_SSID ]] && echo ", Wi-Fi \"$G_WIFI_SSID\" copied from this machine" )
Hostname:      $G_HOSTNAME
User:          $G_USERNAME (member of wheel, can use sudo)
EOF
}
