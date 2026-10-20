# shellcheck shell=bash
# Thin wrappers over dialog (preferred), whiptail (fallback) or plain text
# (unattended installs driven by an answers file).

DIALOG=${DIALOG:-}
BACKTITLE="toboggan ${TOBOGGAN_VERSION} - Gentoo Linux installer"
UI_H=20
UI_W=76

ui_init() {
  if [[ -z $DIALOG ]]; then
    if have dialog; then DIALOG=dialog
    elif have whiptail; then DIALOG=whiptail
    else DIALOG=plain; fi
  fi
  local lines cols
  lines=$(tput lines 2>/dev/null || echo 24)
  cols=$(tput cols 2>/dev/null || echo 80)
  UI_H=$(( lines > 32 ? 28 : lines - 4 ))
  UI_W=$(( cols > 110 ? 100 : cols - 6 ))
  (( UI_H < 16 )) && UI_H=16
  (( UI_W < 60 )) && UI_W=60
  return 0
}

_ui_needs_tty() {
  [[ $DIALOG != plain ]] || die "This step needs dialog or whiptail. For unattended installs use --answers FILE --yes."
}

ui_confirm_quit() {
  if "$DIALOG" --backtitle "$BACKTITLE" --title "Quit" --defaultno \
       --yesno "Quit the installer?" 7 40; then
    clear; exit 130
  fi
}

# The Cancel button's label. Questions use "Back" (which returns to the main
# menu); set UI_CANCEL=Quit for the main menu, or UI_CANCEL="" for no button.
UI_CANCEL=${UI_CANCEL-Back}

_ui_cancel_opts() {
  if [[ -z $UI_CANCEL ]]; then
    if [[ $DIALOG == dialog ]]; then echo --no-cancel; else echo --nocancel; fi
  elif [[ $DIALOG == dialog ]]; then
    printf '%s\n' --cancel-label "$UI_CANCEL"
  else
    printf '%s\n' --cancel-button "$UI_CANCEL"
  fi
}

# Run a dialog that returns a value. Returns 1 on Back/Cancel/Esc, so callers
# write: v=$(ui_radio ...) || return 1
_ui() {
  _ui_needs_tty
  local out rc opts
  mapfile -t opts < <(_ui_cancel_opts)
  out=$("$DIALOG" --backtitle "$BACKTITLE" "${opts[@]}" "$@" 3>&1 1>&2 2>&3); rc=$?
  if (( rc == 0 )); then printf '%s' "$out"; return 0; fi
  return 1
}

ui_msg() {
  if [[ $DIALOG == plain ]]; then printf '\n[%s]\n%b\n' "$1" "$2"; return 0; fi
  "$DIALOG" --backtitle "$BACKTITLE" --title "$1" --msgbox "$2" "$UI_H" "$UI_W"
}

# Returns 0 for Yes, 1 for No, 255 for Esc. In plain mode, Yes only with --yes.
ui_yesno() {
  if [[ $DIALOG == plain ]]; then [[ $ASSUME_YES == 1 ]]; return; fi
  "$DIALOG" --backtitle "$BACKTITLE" --title "$1" --yesno "$2" "$UI_H" "$UI_W"
}

# Two-button question with custom labels; long text scrolls.
# Returns 0 for the first button, 1 for the second, 255 for Esc.
ui_choice() { # title text yes-label no-label
  if [[ $DIALOG == plain ]]; then printf '\n[%s]\n%b\n' "$1" "$2"; [[ $ASSUME_YES == 1 ]]; return; fi
  if [[ $DIALOG == dialog ]]; then
    dialog --backtitle "$BACKTITLE" --title "$1" --yes-label "$3" --no-label "$4" \
      --scrollbar --yesno "$2" "$UI_H" "$UI_W"
  else
    whiptail --backtitle "$BACKTITLE" --title "$1" --yes-button "$3" --no-button "$4" \
      --scrolltext --yesno "$2" "$UI_H" "$UI_W"
  fi
}

ui_input()    { _ui --title "$1" --inputbox "$2" "$UI_H" "$UI_W" "${3:-}"; }
ui_password() { _ui --title "$1" --insecure --passwordbox "$2" "$UI_H" "$UI_W"; }
ui_menu()     { _ui --title "$1" --menu "$2" "$UI_H" "$UI_W" $((UI_H - 9)) "${@:3}"; }
# Menu with the current value preselected: ui_pick title text current tag item...
ui_pick() {
  local def=()
  [[ -n $3 ]] && def=(--default-item "$3")
  _ui --title "$1" "${def[@]}" --menu "$2" "$UI_H" "$UI_W" $((UI_H - 9)) "${@:4}"
}
ui_radio()    { _ui --title "$1" --radiolist "$2" "$UI_H" "$UI_W" $((UI_H - 9)) "${@:3}"; }
ui_check()    { _ui --title "$1" --separate-output --checklist "$2" "$UI_H" "$UI_W" $((UI_H - 9)) "${@:3}"; }

ui_textbox() {
  if [[ $DIALOG == plain ]]; then printf '\n[%s]\n' "$1"; cat "$2"; return 0; fi
  "$DIALOG" --backtitle "$BACKTITLE" --title "$1" --textbox "$2" "$UI_H" "$UI_W" || true
}

# Show streamed command output. whiptail has no progressbox, so print it raw.
ui_progress() {
  if [[ $DIALOG == dialog ]]; then
    dialog --backtitle "$BACKTITLE" --title "$1" --progressbox "$UI_H" "$UI_W"
  else
    cat
  fi
}
