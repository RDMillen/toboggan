# shellcheck shell=bash
# Wi-Fi: detect the live system's active connection, offer to copy it to the
# new system, and write it as a NetworkManager connection at the end.

# Any wireless interface at all (decides whether NetworkManager is needed).
wifi_present() {
  local n
  for n in /sys/class/net/*; do [[ -d $n/wireless ]] && return 0; done
  return 1
}

# The wireless interface currently carrying traffic, if any.
wifi_active_iface() {
  local dev n
  dev=$(ip route show default 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}')
  if [[ -n $dev && -d /sys/class/net/$dev/wireless ]]; then echo "$dev"; return 0; fi
  for n in /sys/class/net/*; do
    if [[ -d $n/wireless && $(cat "$n/operstate" 2>/dev/null) == up ]]; then echo "${n##*/}"; return 0; fi
  done
  return 1
}

# Network name (SSID) the interface is connected to, from whichever tool exists.
wifi_ssid() {
  local i=$1 s=""
  if have iw; then s=$(iw dev "$i" link 2>/dev/null | sed -n 's/^[[:space:]]*SSID: //p'); fi
  if [[ -z $s ]] && have iwgetid; then s=$(iwgetid -r "$i" 2>/dev/null); fi
  if [[ -z $s ]] && have wpa_cli; then s=$(wpa_cli -i "$i" status 2>/dev/null | sed -n 's/^ssid=//p'); fi
  if [[ -z $s ]] && have iwctl; then
    s=$(iwctl station "$i" show 2>/dev/null | sed -E 's/\x1b\[[0-9;]*m//g' |
        sed -n 's/^[[:space:]]*Connected network[[:space:]]*//p' | sed 's/[[:space:]]*$//')
  fi
  [[ -n $s ]] && printf '%s' "$s"
}

# Interactive: offer to copy the active connection. Sets G_WIFI_SSID,
# G_WIFI_KEYMGMT (none|psk|sae), G_WIFI_HIDDEN and the wifi_psk secret.
q_wifi() {
  answer_set G_WIFI_SSID ""
  local iface ssid WIFI_SOURCE="" WIFI_KEYMGMT="" WIFI_HIDDEN=no creds="" p
  iface=$(wifi_active_iface) || return 0
  ssid=$(wifi_ssid "$iface") || true
  if [[ -z $ssid ]]; then
    ui_msg "Wi-Fi" "You're on Wi-Fi ($iface), but toboggan couldn't tell which network, so it can't be copied. NetworkManager will be installed: connect after the first boot with nmtui."
    return 0
  fi
  if have python3; then creds=$(python3 -I "$TOBOGGAN_DIR/lib/wifi-creds.py" "$ssid" "$(secret_path wifi_psk)" 2>/dev/null) || creds=""; fi
  if [[ -n $creds ]]; then eval "$creds"; fi

  case $WIFI_KEYMGMT in
    eap)
      ui_msg "Wi-Fi" "\"$ssid\" uses enterprise (802.1X) sign-in, which toboggan can't copy. NetworkManager will be installed: set it up after the first boot with nmtui."
      return 0 ;;
    none|psk|sae)
      ui_yesno "Wi-Fi" "This machine is connected to the Wi-Fi network \"$ssid\".\n\nCopy this connection to the new system so it connects automatically on first boot?\n\nThe password (found in $WIFI_SOURCE's settings) will be saved in a file only root can read: /etc/NetworkManager/system-connections/." || return 0 ;;
    *)
      ui_yesno "Wi-Fi" "This machine is connected to the Wi-Fi network \"$ssid\", but its password couldn't be found on the live system.\n\nEnter the password now so the new system connects automatically on first boot?" || return 0
      p=$(ui_password "Wi-Fi password" "Password for \"$ssid\" (leave empty for an open network):")
      if [[ -n $p ]]; then secret_set wifi_psk "$p"; WIFI_KEYMGMT=psk; else WIFI_KEYMGMT=none; fi ;;
  esac
  answer_set G_WIFI_SSID "$ssid"
  answer_set G_WIFI_KEYMGMT "$WIFI_KEYMGMT"
  answer_set G_WIFI_HIDDEN "$WIFI_HIDDEN"
}

# NetworkManager keyfile value escaping (GKeyFile): backslash, leading space.
_nm_escape() { local v=${1//\\/\\\\}; [[ $v == " "* ]] && v="\\s${v:1}"; printf '%s' "$v"; }

# SSIDs outside a safe character set are written as a byte list, which
# NetworkManager's keyfile format accepts for any SSID.
_nm_ssid() {
  if [[ $1 =~ ^[A-Za-z0-9\ _.@+-]+$ && $1 != " "* ]]; then printf '%s' "$1"; return; fi
  printf '%s' "$1" | od -An -tu1 -v | tr -s ' \n' ';;' | sed 's/^;//'
}

# Host-side install step: write the connection into the new system.
wifi_install() {
  [[ -n $G_WIFI_SSID ]] || return 0
  local name uuid sec=""
  name=$(printf '%s' "$G_WIFI_SSID" | tr -c 'A-Za-z0-9_.-' '_')
  uuid=$(cat /proc/sys/kernel/random/uuid)
  case $G_WIFI_KEYMGMT in
    psk|sae)
      sec=$(printf '\n[wifi-security]\nkey-mgmt=%s\npsk=%s\n' \
        "$( [[ $G_WIFI_KEYMGMT == sae ]] && echo sae || echo wpa-psk )" \
        "$(_nm_escape "$(cat "$(secret_path wifi_psk)")")") ;;
  esac
  wfile "/etc/NetworkManager/system-connections/$name.nmconnection" 0600 <<EOF
# Copied from the live system by toboggan.
[connection]
id=$(_nm_escape "$G_WIFI_SSID")
uuid=$uuid
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=$(_nm_ssid "$G_WIFI_SSID")
$( [[ $G_WIFI_HIDDEN == yes ]] && echo hidden=true )
$sec

[ipv4]
method=auto

[ipv6]
method=auto
EOF
  echo "Saved the Wi-Fi connection \"$G_WIFI_SSID\" (security: $G_WIFI_KEYMGMT) for NetworkManager."
}