# shellcheck shell=bash
# Hardware detection. hw_report() saves lsmod and the live kernel's config
# (for localmodconfig) plus a hardware summary kept in /var/log/toboggan.

hw_boot_mode()   { if [[ -d /sys/firmware/efi ]]; then echo uefi; else echo bios; fi; }
hw_cpu_vendor()  { awk -F': ' '/^vendor_id/ {print $2; exit}' /proc/cpuinfo; }
hw_mem_mib()     { awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo; }

# One job per CPU, but no more than one per 2 GiB of RAM (C++ builds need it).
hw_default_jobs() {
  local cpus mem j
  cpus=$(nproc)
  mem=$(( $(hw_mem_mib) / 2048 ))
  j=$(( cpus < mem ? cpus : mem ))
  (( j < 1 )) && j=1
  echo "$j"
}

# Map display controllers (PCI class 03xx) to VIDEO_CARDS values.
hw_detect_video_cards() {
  have lspci || return 0
  local v cards=""
  while read -r v; do
    case $v in
      8086) cards+=" intel" ;;
      1002) cards+=" amdgpu radeonsi" ;;
      10de) cards+=" nvidia" ;;
      1af4) cards+=" virgl" ;;
      1b36) cards+=" qxl" ;;
      15ad) cards+=" vmware" ;;
    esac
  done < <(lspci -n | awk '$2 ~ /^03/ {split($3, a, ":"); print a[1]}' | sort -u)
  echo "${cards# }"
}

hw_has_virtio() { have lspci && lspci -n | awk '{print $3}' | grep -q '^1af4:'; }

# name|size|model for each installable disk (no loop, ram or optical devices)
hw_list_disks() {
  lsblk -dpnb -e 1,7,11 -o NAME,SIZE,TYPE,MODEL 2>/dev/null |
    awk '$3 == "disk" { n=$1; s=$2; $1=$2=$3=""; sub(/^ +/, "");
                        printf "%s|%.0fG|%s\n", n, s/1073741824, ($0 == "" ? "-" : $0) }'
}

hw_disk_tran() { lsblk -dno TRAN "$1" 2>/dev/null | tr -d ' '; }

# Hardware report. Deliberately excludes serial numbers, UUIDs and MAC addresses.
hw_report() {
  local d=$HWDIR f n name drv wl
  {
    echo "boot_mode=$(hw_boot_mode)"
    echo "live_kernel=$(uname -r)"
    echo "cpus=$(nproc)"
    echo "mem_mib=$(hw_mem_mib)"
  } >"$d/system.txt"
  if have lspci; then lspci -nnk >"$d/lspci.txt" 2>/dev/null || true; fi
  if have lsusb; then lsusb >"$d/lsusb.txt" 2>/dev/null || true; fi
  lsmod >"$d/lsmod.txt" 2>/dev/null || true
  # First CPU only; drop per-core noise.
  awk 'BEGIN {RS=""} NR == 1 {print; exit}' /proc/cpuinfo |
    grep -Ev '^(apicid|initial apicid|core id|processor|bogomips|cpu MHz)' >"$d/cpuinfo.txt" || true
  for f in sys_vendor product_name product_family board_vendor board_name chassis_type; do
    if [[ -r /sys/class/dmi/id/$f ]]; then printf '%s=%s\n' "$f" "$(<"/sys/class/dmi/id/$f")"; fi
  done >"$d/dmi.txt" 2>/dev/null
  lsblk -dno NAME,TRAN,ROTA,SIZE,MODEL -e 1,7,11 >"$d/block.txt" 2>/dev/null || true
  for n in /sys/class/net/*; do
    name=${n##*/}
    [[ $name == lo ]] && continue
    drv=none
    if [[ -e $n/device/driver ]]; then drv=$(basename "$(readlink -f "$n/device/driver")"); fi
    wl=no
    if [[ -d $n/wireless ]]; then wl=yes; fi
    printf '%s driver=%s wireless=%s\n' "$name" "$drv" "$wl"
  done >"$d/net.txt"
  if [[ -r /proc/config.gz ]]; then cp /proc/config.gz "$d/config-live.gz"; fi
  return 0
}
