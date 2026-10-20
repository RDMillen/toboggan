# shellcheck shell=bash
# The setup flow: on first run the questions go in order; Back (or Esc) on
# any question opens the main menu, which lists every setting with its
# current value. Changing one setting re-asks anything it invalidates.

SECTIONS=(disk filesystem luks swap init desktop graphics wifi kernel initramfs bootloader compile locale identity)
declare -A ANSWERED=()   # sections answered so far
WIZ_POS=0            # next section in first-run order
MENU_DEFAULT=""      # cursor position in the main menu

section_label() {
  case $1 in
    disk) echo "Disk" ;;            filesystem) echo "Filesystem" ;;
    luks) echo "Encryption" ;;      swap) echo "Swap" ;;
    init) echo "Init system" ;;     desktop) echo "Desktop" ;;
    graphics) echo "Graphics" ;;    wifi) echo "Wi-Fi" ;;
    kernel) echo "Kernel" ;;        initramfs) echo "Initramfs" ;;
    bootloader) echo "Bootloader" ;; compile) echo "Compiling" ;;
    locale) echo "Locale" ;;        identity) echo "Users" ;;
  esac
}

section_value() {
  case $1 in
    disk)
      if [[ -z $G_DISK ]]; then echo "not set"
      else echo "$G_DISK  $(lsblk -dno SIZE "$G_DISK" 2>/dev/null | tr -d ' ')"; fi ;;
    filesystem) echo "$G_FS" ;;
    luks) [[ $G_LUKS == yes ]] && echo "LUKS2" || echo "none" ;;
    swap) case $G_SWAP in file) echo "file, ${G_SWAP_SIZE} GiB" ;; *) echo "$G_SWAP" ;; esac ;;
    init) echo "$G_INIT" ;;
    desktop) [[ $G_DESKTOP == none ]] && echo "console only" || echo "$G_DESKTOP" ;;
    graphics)
      if [[ $G_DESKTOP == none ]]; then echo "not needed (console only)"
      else echo "${G_VIDEO_CARDS:-none selected}"; fi ;;
    wifi)
      if [[ -n $G_WIFI_SSID ]]; then echo "copy \"$G_WIFI_SSID\""
      elif wifi_present; then echo "not copied"
      else echo "no Wi-Fi hardware"; fi ;;
    kernel) [[ $G_KERNEL == bin ]] && echo "gentoo-kernel-bin" || echo "gentoo-sources ($G_KCONFIG_BASE)" ;;
    initramfs) echo "$G_INITRAMFS" ;;
    bootloader) echo "$G_BOOTLOADER" ;;
    compile) echo "$G_MARCH, -j$G_JOBS, $( [[ $G_BINPKG == yes ]] && echo "binary packages" || echo "from source" )" ;;
    locale) echo "${G_LOCALE%.UTF-8}, $G_TIMEZONE, $G_KEYMAP" ;;
    identity)
      if [[ -z $G_USERNAME ]]; then echo "not set"
      else echo "$G_HOSTNAME: $G_USERNAME"; fi ;;
  esac
}

# What's wrong with a section, if anything (shown as "!" in the menu).
section_problem() {
  case $1 in
    disk) [[ -n $G_DISK ]] || echo "choose a disk" ;;
    luks) if [[ $G_LUKS == yes && ! -s $(secret_path luks_pass) ]]; then echo "no passphrase"; fi ;;
    graphics) if has_word nvidia "$G_VIDEO_CARDS" && has_word nouveau "$G_VIDEO_CARDS"; then echo "nvidia and nouveau both chosen"; fi ;;
    initramfs)
      if [[ $G_INITRAMFS == none && $G_LUKS == yes ]]; then echo "LUKS needs an initramfs"
      elif [[ $G_INITRAMFS == none && $G_KERNEL == bin ]]; then echo "gentoo-kernel-bin needs an initramfs"; fi ;;
    bootloader) if [[ $G_BOOTMODE == bios && $G_BOOTLOADER != grub ]]; then echo "BIOS needs GRUB"; fi ;;
    wifi) if [[ -n $G_WIFI_SSID && $G_WIFI_KEYMGMT != none && ! -s $(secret_path wifi_psk) ]]; then echo "no password"; fi ;;
    identity)
      if [[ -z $G_USERNAME ]]; then echo "create a user"
      elif [[ ! -s $(secret_path user_pass) || ! -s $(secret_path root_pass) ]]; then echo "passwords not set"; fi ;;
  esac
  return 0
}

run_section() {
  local id=$1 from=${2:-}
  case $id in
    wifi) q_wifi "$from" || return 1 ;;
    graphics)
      if [[ $G_DESKTOP == none && $from == menu ]]; then
        ui_msg "Graphics" "Graphics drivers are only needed with a desktop. Choose one under Desktop first."
        return 0
      fi
      q_graphics || return 1 ;;
    bootloader)
      if [[ $G_BOOTMODE == bios && $from == menu ]]; then
        ui_msg "Bootloader" "This machine booted in BIOS mode, so GRUB is the only option."
      fi
      q_bootloader || return 1 ;;
    *) "q_$id" || return 1 ;;
  esac
  ANSWERED[$id]=1
}

# After a change from the main menu, deal with answers it made invalid.
section_fixups() {
  local id=$1 old_desktop=$2
  if [[ $id == desktop ]]; then
    if [[ $G_DESKTOP == none ]]; then
      answer_set G_VIDEO_CARDS ""
    elif [[ $old_desktop == none ]]; then
      run_section graphics || true
    fi
  fi
  if [[ $id == kernel || $id == luks ]] && [[ -n $(section_problem initramfs) ]]; then
    ui_msg "Initramfs" "$(section_problem initramfs), so please choose one."
    run_section initramfs || true
  fi
  return 0
}

# First run: questions in order from WIZ_POS. Returns 0 when the user has
# confirmed the install; any Back goes to the main menu.
# An answers file was loaded: everything counts as answered.
menu_mark_all_answered() {
  local s
  for s in "${SECTIONS[@]}"; do ANSWERED[$s]=1; done
  # shellcheck disable=SC2034 # read by q_locale in lib/questions.sh
  KEYMAP_CHOSEN=yes
}

# Index of the next unanswered section from WIZ_POS on (or the count if none).
next_undone() {
  local i=$WIZ_POS
  while (( i < ${#SECTIONS[@]} )) && [[ -n ${ANSWERED[${SECTIONS[i]}]:-} ]]; do i=$(( i + 1 )); done
  echo "$i"
}

menu_wizard() {
  while WIZ_POS=$(next_undone); (( WIZ_POS < ${#SECTIONS[@]} )); do
    if ! run_section "${SECTIONS[WIZ_POS]}"; then
      MENU_DEFAULT=$(section_label "${SECTIONS[WIZ_POS]}")
      menu_main; return
    fi
    WIZ_POS=$(( WIZ_POS + 1 ))
  done
  menu_review && return 0
  [[ -n $MENU_DEFAULT ]] || MENU_DEFAULT=Install
  menu_main
}

# Validate, show the summary, confirm. 0 = start installing, 1 = not yet.
menu_review() {
  local errs id
  MENU_DEFAULT=""
  if ! errs=$(validate_config); then
    ui_msg "Not ready yet" "Please fix these first:\n\n$errs"
    for id in "${SECTIONS[@]}"; do
      if [[ -n $(section_problem "$id") ]]; then MENU_DEFAULT=$(section_label "$id"); break; fi
    done
    return 1
  fi
  config_derive
  summary_text >"$RUNDIR/summary.txt"
  confirm_install && return 0
  MENU_DEFAULT=Install
  return 1
}

menu_main() {
  local items=() id label value problem choice old_desktop
  while :; do
    items=()
    for id in "${SECTIONS[@]}"; do
      label=$(section_label "$id")
      value=$(section_value "$id")
      problem=$(section_problem "$id")
      [[ -n $problem ]] && value="! $value  <- $problem"
      items+=("$label" "$value")
    done
    items+=("────────" "")
    WIZ_POS=$(next_undone)
    (( WIZ_POS < ${#SECTIONS[@]} )) && items+=("Continue" "carry on from $(section_label "${SECTIONS[WIZ_POS]}")")
    items+=("Install" "review the summary and start" "Save answers" "write these settings to an answers file")
    choice=$(UI_CANCEL=Quit ui_pick "toboggan" "Choose a setting to change. Settings marked ! need attention." \
             "$MENU_DEFAULT" "${items[@]}") || { ui_confirm_quit; continue; }
    MENU_DEFAULT=$choice
    case $choice in
      "────────") ;;
      Continue) menu_wizard; return ;;
      Install) menu_review && return 0 ;;
      "Save answers") menu_save ;;
      *)
        for id in "${SECTIONS[@]}"; do
          [[ $(section_label "$id") == "$choice" ]] || continue
          old_desktop=$G_DESKTOP
          run_section "$id" menu && section_fixups "$id" "$old_desktop"
        done ;;
    esac
  done
}

# Write the current choices (no passwords) as an answers file.
menu_save() {
  local path k
  path=$(ui_input "Save answers" "Save to (a USB stick is a good place; the live system's files vanish on reboot):" \
         "${SAVE_PATH:-/root/toboggan-answers.conf}") || return 0
  [[ -n $path ]] || return 0
  if ! {
    echo "# toboggan answers, saved $(date -u '+%F %H:%M UTC'). Passwords are not included."
    echo "# Use: ./toboggan --answers $(basename "$path")   (add --yes to skip the review)"
    echo "# For an unattended install, add G_ROOT_PASSWORD, G_USER_PASSWORD (and"
    echo "# G_LUKS_PASSPHRASE / G_WIFI_PASSPHRASE if used)."
    for k in G_DISK G_FS G_LUKS G_SWAP G_SWAP_SIZE G_INIT G_DESKTOP G_VIDEO_CARDS G_WIFI_SSID \
             G_WIFI_KEYMGMT G_WIFI_HIDDEN G_KERNEL G_KCONFIG_BASE G_INITRAMFS G_BOOTLOADER G_MARCH \
             G_BINPKG G_JOBS G_MIRROR G_LOCALE G_TIMEZONE G_KEYMAP G_HOSTNAME G_USERNAME; do
      printf '%s=%q\n' "$k" "${!k}"
    done
  } >"$path" 2>/dev/null; then
    ui_msg "Save answers" "Couldn't write $path. Is the folder there, and writable?"
    return 0
  fi
  SAVE_PATH=$path
  ui_msg "Save answers" "Saved to $path."
}
