# shellcheck shell=bash
# The interactive questionnaire. Each q_* function stores its answer with
# answer_set; current values (from config_defaults) are offered as defaults.

_on() { if [[ $1 == "$2" ]]; then echo on; else echo off; fi; }

q_number() { # title text default min max
  local v
  while :; do
    v=$(ui_input "$1" "$2" "$3")
    if [[ $v =~ ^[0-9]+$ ]] && (( v >= $4 && v <= $5 )); then echo "$v"; return 0; fi
    ui_msg "$1" "Please enter a whole number from $4 to $5."
  done
}

q_new_password() { # secret-name title
  local p1 p2
  while :; do
    p1=$(ui_password "$2" "Enter the ${2,,}:")
    p2=$(ui_password "$2" "Enter it again:")
    if [[ -z $p1 ]]; then ui_msg "$2" "It can't be empty."; continue; fi
    if [[ $p1 != "$p2" ]]; then ui_msg "$2" "The two entries don't match."; continue; fi
    secret_set "$1" "$p1"
    return 0
  done
}

q_welcome() {
  ui_msg "Welcome" "This installs Gentoo Linux (amd64) onto a whole disk.\n\nYou'll answer every question first and review a summary. Nothing is written to disk until you type the disk's name to confirm.\n\nIf a step fails you can retry it, open a shell to fix things, or skip it. The full log is kept in $LOG and copied to /var/log/toboggan on the new system.\n\nDetected: $G_BOOTMODE boot, $(nproc) CPUs, $(( $(hw_mem_mib) / 1024 )) GiB RAM."
}

q_disk() {
  local items=() name size model
  while IFS='|' read -r name size model; do items+=("$name" "$size  $model"); done < <(hw_list_disks)
  (( ${#items[@]} )) || die "No installable disks found."
  answer_set G_DISK "$(ui_menu "Target disk" "Choose the disk to install Gentoo on.\n\nEVERYTHING on this disk will be erased." "${items[@]}")"
}

q_filesystem() {
  answer_set G_FS "$(ui_radio "Root filesystem" "Filesystem for the root partition:" \
    ext4  "Mature and simple; a safe default"                 "$(_on ext4 "$G_FS")" \
    xfs   "Fast with large files; can't be shrunk"            "$(_on xfs "$G_FS")" \
    btrfs "Subvolumes (@, @home), zstd compression, snapshots" "$(_on btrfs "$G_FS")")"
}

q_luks() {
  if ui_yesno "Encryption" "Encrypt the root partition with LUKS2?\n\nThe EFI or /boot partition stays unencrypted so the bootloader can load the kernel; you'll type the passphrase at boot."; then
    answer_set G_LUKS yes
    q_new_password luks_pass "LUKS passphrase"
  else
    answer_set G_LUKS no
  fi
}

q_swap() {
  answer_set G_SWAP "$(ui_radio "Swap" "How should swap be set up?" \
    zram "Compressed swap in RAM (zram)"     "$(_on zram "$G_SWAP")" \
    file "Swap file on the root filesystem" "$(_on file "$G_SWAP")" \
    none "No swap"                          "$(_on none "$G_SWAP")")"
  if [[ $G_SWAP == file ]]; then
    local def=$(( ($(hw_mem_mib) + 1023) / 1024 ))
    (( def > 16 )) && def=16
    answer_set G_SWAP_SIZE "$(q_number "Swap file" "Swap file size in GiB:" "$def" 1 256)"
  fi
}

q_init() {
  answer_set G_INIT "$(ui_radio "Init system" "Choose the init system. This also picks the stage3 and profile." \
    openrc  "OpenRC: Gentoo's default, simple and scriptable" "$(_on openrc "$G_INIT")" \
    systemd "systemd"                                         "$(_on systemd "$G_INIT")")"
}

q_desktop() {
  answer_set G_DESKTOP "$(ui_radio "Desktop" "Desktop environment or window manager.\n\nWithout binary packages, Plasma and GNOME take many hours to compile." \
    none     "Console only"                       "$(_on none "$G_DESKTOP")" \
    plasma   "KDE Plasma (SDDM)"                  "$(_on plasma "$G_DESKTOP")" \
    gnome    "GNOME (GDM)"                        "$(_on gnome "$G_DESKTOP")" \
    xfce     "Xfce on X11 (LightDM)"              "$(_on xfce "$G_DESKTOP")" \
    sway     "Sway, Wayland tiling (log in at the console)"     "$(_on sway "$G_DESKTOP")" \
    hyprland "Hyprland, Wayland tiling (log in at the console)" "$(_on hyprland "$G_DESKTOP")" \
    i3       "i3, X11 tiling (LightDM)"           "$(_on i3 "$G_DESKTOP")")"
}

q_graphics() {
  if [[ $G_DESKTOP == none ]]; then answer_set G_VIDEO_CARDS ""; return 0; fi
  local det sel cards="" t
  det=$(hw_detect_video_cards)
  sel=$(ui_check "Graphics" "Graphics drivers (VIDEO_CARDS). Detected: ${det:-nothing}" \
    intel   "Intel"                          "$(has_word intel "$det" && echo on || echo off)" \
    amdgpu  "AMD (amdgpu + radeonsi)"        "$(has_word amdgpu "$det" && echo on || echo off)" \
    nvidia  "NVIDIA, proprietary driver"     "$(has_word nvidia "$det" && echo on || echo off)" \
    nouveau "NVIDIA, open-source (nouveau)"  off \
    virgl   "VM: virtio-gpu"                 "$(has_word virgl "$det" && echo on || echo off)" \
    qxl     "VM: QXL"                        "$(has_word qxl "$det" && echo on || echo off)" \
    vmware  "VM: VMware SVGA"                "$(has_word vmware "$det" && echo on || echo off)")
  for t in $sel; do
    if [[ $t == amdgpu ]]; then cards+=" amdgpu radeonsi"; else cards+=" $t"; fi
  done
  answer_set G_VIDEO_CARDS "${cards# }"
}

q_kernel() {
  answer_set G_KERNEL "$(ui_radio "Kernel" "Which kernel?" \
    bin     "gentoo-kernel-bin: prebuilt, ready in minutes"                   "$(_on bin "$G_KERNEL")" \
    sources "gentoo-sources: configure it yourself in make menuconfig"        "$(_on sources "$G_KERNEL")")"
  if [[ $G_KERNEL == sources ]]; then
    answer_set G_KCONFIG_BASE "$(ui_radio "Starting config" "What should make menuconfig start from? Either way, the options this install needs to boot (filesystem, storage controller, LUKS, init system, graphics) are switched on for you." \
      localmod  "This machine: the live medium's config, trimmed to the modules loaded now" "$(_on localmod "$G_KCONFIG_BASE")" \
      defconfig "Upstream x86_64 defconfig (small and generic)"                           "$(_on defconfig "$G_KCONFIG_BASE")")"
  fi
}

q_initramfs() {
  local opts=(
    dracut "dracut: the standard, handles LUKS, btrfs and systemd" "$(_on dracut "$G_INITRAMFS")"
    ugrd   "ugrd: small Python-built initramfs (autodetects root)" "$(_on ugrd "$G_INITRAMFS")"
  )
  if [[ $G_KERNEL == sources && $G_LUKS == no ]]; then
    opts+=(none "None: root filesystem and storage drivers built into the kernel" "$(_on none "$G_INITRAMFS")")
  fi
  answer_set G_INITRAMFS "$(ui_radio "Initramfs" "Initramfs generator:" "${opts[@]}")"
}

q_bootloader() {
  if [[ $G_BOOTMODE == bios ]]; then answer_set G_BOOTLOADER grub; return 0; fi
  answer_set G_BOOTLOADER "$(ui_radio "Bootloader" "Bootloader (all entries are kept up to date by installkernel):" \
    grub         "GRUB"                                             "$(_on grub "$G_BOOTLOADER")" \
    systemd-boot "systemd-boot (works with OpenRC too)"             "$(_on systemd-boot "$G_BOOTLOADER")" \
    efistub      "EFI stub, firmware boots the kernel directly (experimental)" "$(_on efistub "$G_BOOTLOADER")")"
}

q_compile() {
  answer_set G_MARCH "$(ui_radio "Compiler target" "CPU target for -march:" \
    native    "This CPU exactly (fastest; binaries may not run elsewhere)" "$(_on native "$G_MARCH")" \
    x86-64-v3 "Haswell / Zen and newer"                                     "$(_on x86-64-v3 "$G_MARCH")" \
    x86-64    "Any 64-bit x86 CPU"                                          "$(_on x86-64 "$G_MARCH")")"
  if ui_yesno "Binary packages" "Use Gentoo's official binary package host where a matching package exists?\n\nThis cuts install time from hours to minutes. Packages are signature-checked, and anything that doesn't match your USE flags is still compiled locally."; then
    answer_set G_BINPKG yes
  else
    answer_set G_BINPKG no
  fi
  answer_set G_JOBS "$(q_number "Parallel jobs" "MAKEOPTS jobs (suggested: one per CPU, at most one per 2 GiB RAM):" "$G_JOBS" 1 512)"
  answer_set G_MIRROR "$(ui_input "Mirror" "Gentoo mirror for the stage3 and source files:" "$G_MIRROR")"
}

q_locale() {
  local v
  while :; do
    v=$(ui_input "Locale" "System locale:" "$G_LOCALE")
    [[ $v =~ ^[a-z]{2,3}_[A-Z]{2}\.UTF-8$ ]] && break
    ui_msg "Locale" "Use the form language_COUNTRY.UTF-8, e.g. en_GB.UTF-8"
  done
  answer_set G_LOCALE "$v"
  while :; do
    v=$(ui_input "Time zone" "Time zone (Region/City):" "$G_TIMEZONE")
    [[ ! -d /usr/share/zoneinfo || -f /usr/share/zoneinfo/$v ]] && break
    ui_msg "Time zone" "Unknown time zone '$v'. Examples: Europe/London, America/New_York, UTC"
  done
  answer_set G_TIMEZONE "$v"
  answer_set G_KEYMAP "$(ui_input "Keyboard" "Console keymap (e.g. us, uk, de, fr):" "$G_KEYMAP")"
}

q_identity() {
  local v
  while :; do
    v=$(ui_input "Hostname" "Hostname:" "$G_HOSTNAME")
    [[ $v =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]] && break
    ui_msg "Hostname" "Letters, digits and hyphens only."
  done
  answer_set G_HOSTNAME "$v"
  while :; do
    v=$(ui_input "User" "Name of your everyday user account:" "$G_USERNAME")
    [[ $v =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && break
    ui_msg "User" "Lowercase letters, digits, - and _ only, starting with a letter."
  done
  answer_set G_USERNAME "$v"
  q_new_password user_pass "Password for $G_USERNAME"
  q_new_password root_pass "Root password"
}

q_all() {
  q_welcome
  q_disk; q_filesystem; q_luks; q_swap
  q_init; q_desktop; q_graphics
  q_kernel; q_initramfs; q_bootloader
  q_compile; q_locale; q_identity
}
