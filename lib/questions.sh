# shellcheck shell=bash
# The interactive questions. Each q_* function stores its answers with
# answer_set, offers the current values as defaults, and returns 1 if the
# user pressed Back (or Esc), which takes them to the main menu.

DATA_DIR="$TOBOGGAN_DIR/data"

_on() { if [[ $1 == "$2" ]]; then echo on; else echo off; fi; }

q_number() { # title text default min max
  local v
  while :; do
    v=$(ui_input "$1" "$2" "$3") || return 1
    if [[ $v =~ ^[0-9]+$ ]] && (( v >= $4 && v <= $5 )); then echo "$v"; return 0; fi
    ui_msg "$1" "Please enter a whole number from $4 to $5."
  done
}

q_new_password() { # secret-name title
  local p1 p2 rc
  # Revisiting: keep what was already entered?
  if [[ -s $(secret_path "$1") ]]; then
    ui_choice "$2" "Keep the ${2,,} you entered earlier?" "Keep" "Change"; rc=$?
    (( rc == 0 )) && return 0
    (( rc == 255 )) && return 1
  fi
  while :; do
    p1=$(ui_password "$2" "Enter the ${2,,}:") || return 1
    p2=$(ui_password "$2" "Enter it again:") || return 1
    if [[ -z $p1 ]]; then ui_msg "$2" "It can't be empty."; continue; fi
    if [[ $p1 != "$p2" ]]; then ui_msg "$2" "The two entries don't match."; continue; fi
    secret_set "$1" "$p1"
    return 0
  done
}

# Menu built from a bundled data file ("value|description" lines), with the
# current value preselected. Prints the chosen value.
q_pick_from() { # title text file current [grep-filter]
  local items=() val desc
  while IFS='|' read -r val desc; do
    [[ -z $val || $val == \#* ]] && continue
    items+=("$val" "${desc:--}")
  done < <(if [[ -n ${5:-} ]]; then grep -E "$5" "$3"; else cat "$3"; fi)
  (( ${#items[@]} )) || return 1
  ui_pick "$1" "$2" "$4" "${items[@]}"
}

q_welcome() {
  ui_msg "Welcome" "This installs Gentoo Linux (amd64) onto a whole disk.\n\nThe questions run in order. Press Back (or Esc) at any point to see the main menu, where every setting is listed and can be changed. Nothing is written to disk until you've reviewed a summary and typed the disk's name to confirm.\n\nIf a step fails you can retry it, open a shell to fix things, or skip it. The full log is kept in $LOG and copied to /var/log/toboggan on the new system.\n\nDetected: $G_BOOTMODE boot, $(nproc) CPUs, $(( $(hw_mem_mib) / 1024 )) GiB RAM."
}

q_disk() {
  local items=() name size model v
  while IFS='|' read -r name size model; do items+=("$name" "$size  $model"); done < <(hw_list_disks)
  (( ${#items[@]} )) || die "No installable disks found."
  v=$(ui_pick "Target disk" "Choose the disk to install Gentoo on.\n\nEVERYTHING on this disk will be erased." "$G_DISK" "${items[@]}") || return 1
  answer_set G_DISK "$v"
}

q_filesystem() {
  local v
  v=$(ui_radio "Root filesystem" "Filesystem for the root partition:" \
    ext4  "Mature and simple; a safe default"                 "$(_on ext4 "$G_FS")" \
    xfs   "Fast with large files; can't be shrunk"            "$(_on xfs "$G_FS")" \
    btrfs "Subvolumes (@, @home), zstd compression, snapshots" "$(_on btrfs "$G_FS")") || return 1
  answer_set G_FS "$v"
}

q_luks() {
  local v
  v=$(ui_radio "Encryption" "Encrypt the root partition with LUKS2?\n\nThe EFI or /boot partition stays unencrypted so the bootloader can load the kernel; you'll type the passphrase at boot." \
    no  "No encryption"                 "$(_on no "$G_LUKS")" \
    yes "Encrypt the root partition"    "$(_on yes "$G_LUKS")") || return 1
  answer_set G_LUKS "$v"
  if [[ $v == yes ]]; then q_new_password luks_pass "LUKS passphrase" || return 1; fi
}

q_swap() {
  local v def
  v=$(ui_radio "Swap" "How should swap be set up?" \
    zram "Compressed swap in RAM (zram)"     "$(_on zram "$G_SWAP")" \
    file "Swap file on the root filesystem" "$(_on file "$G_SWAP")" \
    none "No swap"                          "$(_on none "$G_SWAP")") || return 1
  answer_set G_SWAP "$v"
  if [[ $v == file ]]; then
    def=$(( ($(hw_mem_mib) + 1023) / 1024 )); (( def > 16 )) && def=16
    v=$(q_number "Swap file" "Swap file size in GiB:" "$def" 1 256) || return 1
    answer_set G_SWAP_SIZE "$v"
  fi
}

q_init() {
  local v
  v=$(ui_radio "Init system" "Choose the init system. This also picks the stage3 and profile." \
    openrc  "OpenRC: Gentoo's default, simple and scriptable" "$(_on openrc "$G_INIT")" \
    systemd "systemd"                                         "$(_on systemd "$G_INIT")") || return 1
  answer_set G_INIT "$v"
}

q_desktop() {
  local v
  v=$(ui_radio "Desktop" "Desktop environment or window manager.\n\nCompiled from source, Plasma and GNOME can take many hours (binary packages are offered later)." \
    none     "Console only"                       "$(_on none "$G_DESKTOP")" \
    plasma   "KDE Plasma (SDDM)"                  "$(_on plasma "$G_DESKTOP")" \
    gnome    "GNOME (GDM)"                        "$(_on gnome "$G_DESKTOP")" \
    xfce     "Xfce on X11 (LightDM)"              "$(_on xfce "$G_DESKTOP")" \
    sway     "Sway, Wayland tiling (log in at the console)"     "$(_on sway "$G_DESKTOP")" \
    hyprland "Hyprland, Wayland tiling (log in at the console)" "$(_on hyprland "$G_DESKTOP")" \
    i3       "i3, X11 tiling (LightDM)"           "$(_on i3 "$G_DESKTOP")") || return 1
  answer_set G_DESKTOP "$v"
}

q_graphics() {
  if [[ $G_DESKTOP == none ]]; then answer_set G_VIDEO_CARDS ""; return 0; fi
  local det sel cards="" t cur=${G_VIDEO_CARDS:-}
  det=$(hw_detect_video_cards)
  [[ -z $cur ]] && cur=$det
  sel=$(ui_check "Graphics" "Graphics drivers (VIDEO_CARDS). Detected: ${det:-nothing}" \
    intel   "Intel"                          "$(has_word intel "$cur" && echo on || echo off)" \
    amdgpu  "AMD (amdgpu + radeonsi)"        "$(has_word amdgpu "$cur" && echo on || echo off)" \
    nvidia  "NVIDIA, proprietary driver"     "$(has_word nvidia "$cur" && echo on || echo off)" \
    nouveau "NVIDIA, open-source (nouveau)"  "$(has_word nouveau "$cur" && echo on || echo off)" \
    virgl   "VM: virtio-gpu"                 "$(has_word virgl "$cur" && echo on || echo off)" \
    qxl     "VM: QXL"                        "$(has_word qxl "$cur" && echo on || echo off)" \
    vmware  "VM: VMware SVGA"                "$(has_word vmware "$cur" && echo on || echo off)") || return 1
  for t in $sel; do
    if [[ $t == amdgpu ]]; then cards+=" amdgpu radeonsi"; else cards+=" $t"; fi
  done
  answer_set G_VIDEO_CARDS "${cards# }"
}

q_kernel() {
  local v
  v=$(ui_radio "Kernel" "Which kernel? (How the rest of the system is installed is asked separately.)" \
    bin     "gentoo-kernel-bin: prebuilt, ready in minutes"                   "$(_on bin "$G_KERNEL")" \
    sources "gentoo-sources: configure it yourself in make menuconfig"        "$(_on sources "$G_KERNEL")") || return 1
  answer_set G_KERNEL "$v"
  if [[ $v == sources ]]; then
    v=$(ui_radio "Starting config" "What should make menuconfig start from? Either way, the options this install needs to boot (filesystem, storage controller, LUKS, init system, graphics) are switched on for you." \
      localmod  "This machine: the live medium's config, trimmed to the modules loaded now" "$(_on localmod "$G_KCONFIG_BASE")" \
      defconfig "Upstream x86_64 defconfig (small and generic)"                           "$(_on defconfig "$G_KCONFIG_BASE")") || return 1
    answer_set G_KCONFIG_BASE "$v"
  fi
}

q_initramfs() {
  local v opts=(
    dracut "dracut: the standard, handles LUKS, btrfs and systemd" "$(_on dracut "$G_INITRAMFS")"
    ugrd   "ugrd: small Python-built initramfs (autodetects root)" "$(_on ugrd "$G_INITRAMFS")"
  )
  if [[ $G_KERNEL == sources && $G_LUKS == no ]]; then
    opts+=(none "None: root filesystem and storage drivers built into the kernel" "$(_on none "$G_INITRAMFS")")
  fi
  v=$(ui_radio "Initramfs" "Initramfs generator:" "${opts[@]}") || return 1
  answer_set G_INITRAMFS "$v"
}

q_bootloader() {
  local v
  if [[ $G_BOOTMODE == bios ]]; then
    answer_set G_BOOTLOADER grub
    return 0
  fi
  v=$(ui_radio "Bootloader" "Bootloader (all entries are kept up to date by installkernel):" \
    grub         "GRUB"                                             "$(_on grub "$G_BOOTLOADER")" \
    systemd-boot "systemd-boot (works with OpenRC too)"             "$(_on systemd-boot "$G_BOOTLOADER")" \
    efistub      "EFI stub, firmware boots the kernel directly (experimental)" "$(_on efistub "$G_BOOTLOADER")") || return 1
  answer_set G_BOOTLOADER "$v"
}

q_compile() {
  local v
  v=$(ui_radio "Compiler target" "CPU target for -march:" \
    native    "This CPU exactly (fastest; binaries may not run elsewhere)" "$(_on native "$G_MARCH")" \
    x86-64-v3 "Haswell / Zen and newer"                                     "$(_on x86-64-v3 "$G_MARCH")" \
    x86-64    "Any 64-bit x86 CPU"                                          "$(_on x86-64 "$G_MARCH")") || return 1
  answer_set G_MARCH "$v"
  v=$(ui_radio "Packages" "How should packages (everything except the kernel, which you chose earlier) be installed?\n\nBinary packages come from Gentoo's signed binary host and cut install time from hours to minutes, but they're built for generic x86-64, not your -march setting. Anything that doesn't match your USE flags is still compiled." \
    no  "Compile everything from source"            "$(_on no "$G_BINPKG")" \
    yes "Use binary packages where they match"      "$(_on yes "$G_BINPKG")") || return 1
  answer_set G_BINPKG "$v"
  v=$(q_number "Parallel jobs" "MAKEOPTS jobs (suggested: one per CPU, at most one per 2 GiB RAM):" "$G_JOBS" 1 512) || return 1
  answer_set G_JOBS "$v"
  v=$(ui_input "Mirror" "Gentoo mirror for the stage3 and source files:" "$G_MIRROR") || return 1
  answer_set G_MIRROR "$v"
}

# Suggested console keymap for a locale's country (used until the user picks one).
keymap_for_locale() {
  case ${1#*_} in
    GB.*) echo uk ;;          US.*|CA.*|AU.*|NZ.*) echo us ;;
    DE.*|AT.*) echo de-latin1 ;; CH.*) echo de_CH-latin1 ;;
    FR.*) echo fr-latin9 ;;   BE.*) echo be-latin1 ;;   NL.*) echo us ;;
    ES.*) echo es ;;          IT.*) echo it ;;          PT.*) echo pt-latin1 ;;
    BR.*) echo br-abnt2 ;;    SE.*) echo se-lat6 ;;     NO.*) echo no-latin1 ;;
    DK.*) echo dk-latin1 ;;   FI.*) echo "fi" ;;         PL.*) echo pl2 ;;
    CZ.*) echo cz ;;          HU.*) echo hu ;;          RU.*) echo ru ;;
    UA.*) echo ua ;;          JP.*) echo jp106 ;;       IE.*) echo ie ;;
    TR.*) echo trq ;;         GR.*) echo gr ;;          IL.*) echo il ;;
    *) echo "" ;;
  esac
}

q_locale() {
  local v region km
  v=$(q_pick_from "Locale" "System language and formats (UTF-8). Type the first letter to jump." \
      "$DATA_DIR/locales.txt" "$G_LOCALE") || return 1
  answer_set G_LOCALE "$v"

  # Time zone: region first, then the zone (about 300 in all).
  local regions=() r cur_region=${G_TIMEZONE%%/*}
  for r in $(grep -v '^#' "$DATA_DIR/timezones.txt" | cut -d'|' -f1 | cut -d/ -f1 | sort -u); do
    regions+=("$r" "$( [[ $r == UTC ]] && echo "Coordinated Universal Time" || echo "$(grep -c "^$r/" "$DATA_DIR/timezones.txt") zones" )")
  done
  region=$(ui_pick "Time zone" "Region:" "$cur_region" "${regions[@]}") || return 1
  if [[ $region == UTC ]]; then
    v=UTC
  else
    v=$(q_pick_from "Time zone" "Time zone in $region:" "$DATA_DIR/timezones.txt" "$G_TIMEZONE" "^$region/") || return 1
  fi
  answer_set G_TIMEZONE "$v"

  km=$G_KEYMAP
  if [[ ${KEYMAP_CHOSEN:-no} != yes ]]; then
    km=$(keymap_for_locale "$G_LOCALE"); km=${km:-$G_KEYMAP}
  fi
  v=$(q_pick_from "Keyboard" "Console keymap (the layout used at the login prompt and in the console):" \
      "$DATA_DIR/keymaps.txt" "$km") || return 1
  answer_set G_KEYMAP "$v"
  KEYMAP_CHOSEN=yes
}

q_identity() {
  local v
  while :; do
    v=$(ui_input "Hostname" "Hostname:" "$G_HOSTNAME") || return 1
    [[ $v =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]] && break
    ui_msg "Hostname" "Letters, digits and hyphens only."
  done
  answer_set G_HOSTNAME "$v"
  while :; do
    v=$(ui_input "User" "Name of your everyday user account:" "$G_USERNAME") || return 1
    [[ $v =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && break
    ui_msg "User" "Lowercase letters, digits, - and _ only, starting with a letter."
  done
  answer_set G_USERNAME "$v"
  q_new_password user_pass "Password for $G_USERNAME" || return 1
  q_new_password root_pass "Root password" || return 1
}
