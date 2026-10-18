#!/bin/bash
# toboggan stage 2: runs INSIDE the new system's chroot, one step per call:
#   stage2.sh <step>
# Settings come from /run/toboggan (bind-mounted from the live system).
# SPDX-License-Identifier: GPL-3.0-or-later
set -Eeuo pipefail
trap 'echo "stage2: \"$BASH_COMMAND\" failed at line $LINENO" >&2' ERR

R=/run/toboggan
KDIR=$R/kernel

set +eu
# shellcheck source=/dev/null
source /etc/profile
set -eu
# shellcheck source=/dev/null
source "$R/answers.sh"
# shellcheck source=/dev/null
source "$R/state.sh"

has_word() { [[ " $2 " == *" $1 "* ]]; }
hash_secret() { openssl passwd -6 -stdin <"$R/secrets/$1"; }

svc() { # service [runlevel]
  if [[ $G_INIT == openrc ]]; then
    if [[ -e /etc/init.d/$1 ]]; then rc-update add "$1" "${2:-default}"; else echo "note: no init script for $1"; fi
  else
    systemctl enable "$1"
  fi
}

display_manager() {
  case $G_DESKTOP in
    plasma) echo sddm ;;
    gnome) echo gdm ;;
    xfce|i3) echo lightdm ;;
    *) echo "" ;;
  esac
}

s_sync() {
  mkdir -p /var/db/repos/gentoo
  emerge-webrsync
  if [[ $G_BINPKG == yes ]] && command -v getuto >/dev/null; then getuto; fi
}

s_profile() {
  local want
  want=$(eselect profile list | awk '{print $2}' |
         grep -E "^default/linux/amd64/[0-9.]+${G_PROFILE_SUFFIX}\$" | sort -V | tail -n1 || true)
  if [[ -z $want ]]; then
    echo "No profile matches default/linux/amd64/<version>${G_PROFILE_SUFFIX}. Available:"
    eselect profile list
    return 1
  fi
  eselect profile set "$want"
  echo "Profile: $want"
}

s_cpuflags() {
  emerge --oneshot --noreplace app-portage/cpuid2cpuflags
  echo "*/* $(cpuid2cpuflags)" >/etc/portage/package.use/00cpu-flags
  cat /etc/portage/package.use/00cpu-flags
}

s_locale() {
  if [[ ! -e /usr/share/zoneinfo/$G_TIMEZONE ]]; then
    echo "Unknown time zone: $G_TIMEZONE (not in /usr/share/zoneinfo)."
    echo "Fix it with: ln -sf ../usr/share/zoneinfo/<Region/City> /etc/localtime"
    echo "then skip this step, or correct G_TIMEZONE in /run/toboggan/answers.sh and retry."
    return 1
  fi
  ln -sf "../usr/share/zoneinfo/$G_TIMEZONE" /etc/localtime
  echo "Time zone: $G_TIMEZONE"
  locale-gen
  eselect locale set "${G_LOCALE%%.*}.utf8" || eselect locale set C.utf8
  env-update
}

s_world() {
  emerge --update --deep --newuse @world
}

s_base() {
  local p=(sys-kernel/linux-firmware sys-kernel/installkernel sys-fs/dosfstools
           sys-apps/pciutils sys-apps/usbutils app-admin/sudo app-shells/bash-completion)
  if grep -q GenuineIntel /proc/cpuinfo; then p+=(sys-firmware/intel-microcode); fi
  case $G_FS in xfs) p+=(sys-fs/xfsprogs) ;; btrfs) p+=(sys-fs/btrfs-progs) ;; esac
  if [[ $G_LUKS == yes ]]; then p+=(sys-fs/cryptsetup); fi
  case $G_INITRAMFS in dracut) p+=(sys-kernel/dracut) ;; ugrd) p+=(sys-kernel/ugrd) ;; esac
  if [[ $G_BOOTMODE == uefi ]]; then p+=(sys-boot/efibootmgr); fi
  if [[ $G_DESKTOP != none ]]; then p+=(net-misc/networkmanager); else p+=(net-misc/dhcpcd); fi
  if [[ $G_INIT == openrc ]]; then p+=(app-admin/sysklogd sys-process/cronie net-misc/chrony); fi
  if [[ $G_SWAP == zram ]]; then
    if [[ $G_INIT == openrc ]]; then p+=(sys-block/zram-init); else p+=(sys-apps/zram-generator); fi
  fi
  emerge --noreplace "${p[@]}"
}

s_bootloader() {
  case $G_BOOTLOADER in
    grub)
      emerge --noreplace sys-boot/grub
      if ! grep -q '^# Added by toboggan' /etc/default/grub; then
        {
          echo
          echo '# Added by toboggan'
          if [[ -n $G_GRUB_CMDLINE ]]; then echo "GRUB_CMDLINE_LINUX=\"$G_GRUB_CMDLINE\""; fi
          if [[ $G_INITRAMFS == none ]]; then
            # No initramfs: boot with root=PARTUUID, which the kernel resolves itself.
            echo 'GRUB_DISABLE_LINUX_UUID=true'
            echo 'GRUB_DISABLE_LINUX_PARTUUID=false'
          fi
        } >>/etc/default/grub
      fi
      if [[ $G_BOOTMODE == uefi ]]; then
        grub-install --target=x86_64-efi --efi-directory="$G_BOOT_MNT" --bootloader-id=Gentoo
        # Also install the fallback path (EFI/BOOT/BOOTX64.EFI) for firmware that forgets NVRAM entries.
        grub-install --target=x86_64-efi --efi-directory="$G_BOOT_MNT" --removable
      else
        grub-install --target=i386-pc "$G_DISK"
      fi
      ;;
    systemd-boot)
      bootctl install --esp-path="$G_BOOT_MNT"
      ;;
    efistub)
      echo "EFI stub: installkernel creates the firmware boot entry when the kernel is installed."
      ;;
  esac
}

s_kernel_package() {
  case $G_KERNEL in
    bin) emerge --noreplace sys-kernel/gentoo-kernel-bin ;;
  esac
}

s_kernel_prepare() {
  emerge --noreplace sys-kernel/gentoo-sources
  eselect kernel set 1
  cd /usr/src/linux
  if [[ $G_KCONFIG_BASE == localmod && -r $R/hw/config-live.gz ]]; then
    echo "Base: the live medium's config, trimmed to the modules it had loaded"
    zcat "$R/hw/config-live.gz" >.config
    make olddefconfig
    { yes '' || true; } | make LSMOD="$R/hw/lsmod.txt" localmodconfig
  else
    if [[ $G_KCONFIG_BASE == localmod ]]; then echo "The live kernel has no /proc/config.gz; using defconfig instead."; fi
    make defconfig
  fi
  cp .config .config.toboggan-base
}

# List required options the current .config doesn't satisfy. Options that
# don't exist in this kernel version are ignored.
kconfig_verify() {
  local line sym want got
  if [[ ! -s $KDIR/symbols.txt ]]; then
    grep -rhoE --include='Kconfig*' '^[[:space:]]*(menu)?config [A-Za-z0-9_]+' . |
      awk '{print "CONFIG_" $2}' | sort -u >"$KDIR/symbols.txt"
  fi
  while IFS= read -r line; do
    if [[ $line =~ ^(CONFIG_[A-Za-z0-9_]+)=(.*)$ ]]; then sym=${BASH_REMATCH[1]}; want=${BASH_REMATCH[2]}
    elif [[ $line =~ ^#\ (CONFIG_[A-Za-z0-9_]+)\ is\ not\ set$ ]]; then sym=${BASH_REMATCH[1]}; want=n
    else continue; fi
    grep -qx "$sym" "$KDIR/symbols.txt" || continue
    got=$(grep -E "^$sym=" .config | head -n1 | cut -d= -f2- || true)
    [[ -z $got ]] && got=n
    [[ $got == "$want" ]] && continue
    [[ $want == m && $got == y ]] && continue
    echo "$sym should be $want (now $got)"
  done <"$KDIR/required.config"
}

merge_required() {
  ./scripts/kconfig/merge_config.sh -m .config "$KDIR/required.config"
  make olddefconfig
}

s_kernel_config() {
  cd /usr/src/linux
  cp .config.toboggan-base .config
  merge_required
  s_kernel_verify
}

# After menuconfig: report required options that are no longer set.
s_kernel_verify() {
  cd /usr/src/linux
  kconfig_verify >"$KDIR/verify.txt"
  if [[ -s $KDIR/verify.txt ]]; then cat "$KDIR/verify.txt"; else echo "All required options are set."; fi
  cp .config "$KDIR/final.config"
}

# Put the required options back on top of the user's edited config.
s_kernel_restore() {
  cd /usr/src/linux
  merge_required
  s_kernel_verify
}

s_kernel_build() {
  cd /usr/src/linux
  make -j"$G_JOBS"
  make modules_install
  # installkernel builds the initramfs and updates the bootloader.
  make install
}

s_graphics() {
  if has_word nvidia "$G_VIDEO_CARDS"; then emerge --noreplace x11-drivers/nvidia-drivers; fi
  return 0
}

s_desktop() {
  local p=() dm
  case $G_DESKTOP in
    plasma)   p=(kde-plasma/plasma-meta kde-apps/konsole kde-apps/dolphin) ;;
    gnome)    p=(gnome-base/gnome-light gnome-base/gdm) ;;
    xfce)     p=(xfce-base/xfce4-meta x11-terms/xfce4-terminal x11-base/xorg-server x11-misc/lightdm) ;;
    i3)       p=(x11-wm/i3 x11-misc/i3status x11-misc/dmenu x11-terms/xterm x11-base/xorg-server x11-misc/lightdm) ;;
    sway)     p=(gui-wm/sway gui-apps/foot) ;;
    hyprland) p=(gui-wm/hyprland gui-apps/foot) ;;
    none)     return 0 ;;
  esac
  p+=(media-video/pipewire media-video/wireplumber media-fonts/noto)
  dm=$(display_manager)
  if [[ $G_INIT == openrc && -n $dm ]]; then p+=(gui-libs/display-manager-init); fi
  emerge --noreplace "${p[@]}"
}

s_users() {
  usermod -p "$(hash_secret root_pass)" root
  local groups=() g
  for g in wheel users audio video input usb plugdev; do
    if getent group "$g" >/dev/null; then groups+=("$g"); fi
  done
  if ! id "$G_USERNAME" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G "$(IFS=,; echo "${groups[*]}")" "$G_USERNAME"
  fi
  usermod -p "$(hash_secret user_pass)" "$G_USERNAME"
  printf '%%wheel ALL=(ALL:ALL) ALL\n' >/etc/sudoers.d/10-wheel
  chmod 0440 /etc/sudoers.d/10-wheel
  echo "Created $G_USERNAME (groups: ${groups[*]})"
}

s_services() {
  local dm mem
  if [[ $G_INIT == systemd ]]; then
    systemd-machine-id-setup
    systemctl preset-all --preset-mode=enable-only
    svc systemd-timesyncd
  else
    svc sysklogd; svc cronie; svc chronyd
  fi
  if [[ $G_DESKTOP != none ]]; then svc NetworkManager; else svc dhcpcd; fi

  if [[ $G_DESKTOP != none && $G_INIT == openrc ]]; then svc elogind boot; svc dbus; fi
  dm=$(display_manager)
  if [[ -n $dm ]]; then
    if [[ $G_INIT == openrc ]]; then
      sed -i "s/^DISPLAYMANAGER=.*/DISPLAYMANAGER=\"$dm\"/" /etc/conf.d/display-manager
      svc display-manager
    else
      svc "$dm"
    fi
  fi

  if [[ $G_SWAP == zram ]]; then
    mem=$(awk '/^MemTotal:/ {printf "%d", $2/1024/2}' /proc/meminfo)
    if [[ $G_INIT == openrc ]]; then
      cat >/etc/conf.d/zram-init <<EOF
# Generated by toboggan: one zram swap device, half of RAM, zstd.
load_on_start="yes"
unload_on_stop="yes"
num_devices="1"
type0="swap"
flag0=
size0="$mem"
maxs0=1
algo0="zstd"
labl0="zram_swap"
EOF
      svc zram-init boot
    else
      printf '[zram0]\nzram-size = min(ram / 2, 8192)\ncompression-algorithm = zstd\n' >/etc/systemd/zram-generator.conf
    fi
  fi
}

s_finalize() {
  if [[ $G_BOOTLOADER == grub ]]; then grub-mkconfig -o /boot/grub/grub.cfg; fi
  echo "Kernels and boot files:"
  find /boot "$G_BOOT_MNT" -maxdepth 5 -type f \
    \( -name 'vmlinuz*' -o -name 'kernel-*' -o -name 'linux' -o -name 'initr*' -o -name '*.efi' -o -name 'grub.cfg' \) \
    -printf '  %p (%s bytes)\n' 2>/dev/null | sort -u
}

step=${1:?usage: stage2.sh <step>}
fn="s_${step//-/_}"
if ! declare -F "$fn" >/dev/null; then echo "Unknown step: $step" >&2; exit 2; fi
echo "--- stage2: $step ---"
"$fn"