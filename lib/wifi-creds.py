#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Find the saved credentials for a Wi-Fi network on the live system.

Looks where the common Wi-Fi tools keep them:
  iwd              /var/lib/iwd/<ssid>.psk | .open | .8021x
  wpa_supplicant   /etc/wpa_supplicant/*.conf, /etc/wpa_supplicant.conf, and
                   any -c config passed to a running wpa_supplicant
  NetworkManager   /etc/NetworkManager/system-connections/, /run/NetworkManager/...

Usage: wifi-creds.py SSID SECRET_FILE [--root DIR]
Prints shell assignments (WIFI_SOURCE, WIFI_KEYMGMT=none|psk|sae|eap,
WIFI_HIDDEN=yes|no). The passphrase is written to SECRET_FILE (mode 600),
never printed. Exit 1 if nothing was found for the SSID.
"""
import configparser
import glob
import os
import re
import shlex
import sys


def iwd_names(ssid):
    """iwd stores plain names as-is and anything else as '=' + hex."""
    names = []
    if re.fullmatch(r"[A-Za-z0-9 _-]+", ssid):
        names.append(ssid)
    names.append("=" + ssid.encode().hex())
    return names


def from_iwd(root, ssid):
    for name in iwd_names(ssid):
        base = os.path.join(root, "var/lib/iwd", name)
        if os.path.exists(base + ".8021x"):
            return dict(source="iwd", keymgmt="eap")
        if os.path.exists(base + ".open"):
            return dict(source="iwd", keymgmt="none")
        if os.path.exists(base + ".psk"):
            cp = configparser.ConfigParser(interpolation=None)
            cp.optionxform = str
            cp.read(base + ".psk")
            sec = cp["Security"] if cp.has_section("Security") else {}
            psk = sec.get("Passphrase") or sec.get("PreSharedKey")
            hidden = cp.get("Settings", "Hidden", fallback="false").lower() == "true"
            if psk:
                return dict(source="iwd", keymgmt="psk", psk=psk, hidden=hidden)
    return None


def wpa_config_paths(root):
    paths = set(glob.glob(os.path.join(root, "etc/wpa_supplicant/*.conf")))
    paths.add(os.path.join(root, "etc/wpa_supplicant.conf"))
    if root == "/":
        for cmd in glob.glob("/proc/[0-9]*/cmdline"):
            try:
                args = open(cmd, "rb").read().split(b"\0")
            except OSError:
                continue
            if not args or not args[0].endswith(b"wpa_supplicant"):
                continue
            for i, a in enumerate(args):
                if a == b"-c" and i + 1 < len(args):
                    paths.add(args[i + 1].decode(errors="replace"))
                elif a.startswith(b"-c") and len(a) > 2:
                    paths.add(a[2:].decode(errors="replace"))
    return [p for p in paths if os.path.isfile(p)]


def wpa_value(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] == '"':
        return v[1:-1]
    return v


def from_wpa(root, ssid):
    for path in wpa_config_paths(root):
        try:
            text = open(path, errors="replace").read()
        except OSError:
            continue
        for block in re.findall(r"network\s*=\s*\{(.*?)\}", text, re.S):
            kv = {}
            for line in block.splitlines():
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, v = line.split("=", 1)
                    kv[k.strip()] = v.strip()
            raw = kv.get("ssid", "")
            name = wpa_value(raw) if raw.startswith('"') else (
                bytes.fromhex(raw).decode(errors="replace") if re.fullmatch(r"[0-9a-fA-F]+", raw) else raw)
            if name != ssid:
                continue
            km = kv.get("key_mgmt", "WPA-PSK").upper()
            hidden = kv.get("scan_ssid", "0") == "1"
            if "EAP" in km:
                return dict(source="wpa_supplicant", keymgmt="eap")
            if km == "NONE":
                return dict(source="wpa_supplicant", keymgmt="none", hidden=hidden)
            psk = kv.get("psk") or kv.get("sae_password")
            if psk:
                return dict(source="wpa_supplicant", keymgmt="sae" if "SAE" in km and "PSK" not in km else "psk",
                            psk=wpa_value(psk), hidden=hidden)
    return None


def from_nm(root, ssid):
    files = []
    for d in ("etc/NetworkManager/system-connections", "run/NetworkManager/system-connections"):
        files += glob.glob(os.path.join(root, d, "*"))
    for path in files:
        cp = configparser.ConfigParser(interpolation=None)
        cp.optionxform = str
        try:
            cp.read(path)
        except (configparser.Error, OSError):
            continue
        if cp.get("wifi", "ssid", fallback=None) != ssid:
            continue
        km = cp.get("wifi-security", "key-mgmt", fallback="none")
        hidden = cp.get("wifi", "hidden", fallback="false").lower() == "true"
        if km in ("wpa-eap", "ieee8021x", "wpa-eap-suite-b-192"):
            return dict(source="NetworkManager", keymgmt="eap")
        if km == "none" and not cp.has_option("wifi-security", "psk"):
            return dict(source="NetworkManager", keymgmt="none", hidden=hidden)
        psk = cp.get("wifi-security", "psk", fallback=None)
        if psk:
            return dict(source="NetworkManager", keymgmt="sae" if km == "sae" else "psk", psk=psk, hidden=hidden)
    return None


def main():
    args = sys.argv[1:]
    root = "/"
    if "--root" in args:
        i = args.index("--root")
        root = args[i + 1]
        del args[i:i + 2]
    ssid, secret_file = args[0], args[1]
    found = from_iwd(root, ssid) or from_wpa(root, ssid) or from_nm(root, ssid)
    if not found:
        return 1
    if found.get("psk"):
        old = os.umask(0o077)
        with open(secret_file, "w") as f:
            f.write(found["psk"])
        os.umask(old)
    print(f"WIFI_SOURCE={shlex.quote(found['source'])}")
    print(f"WIFI_KEYMGMT={shlex.quote(found['keymgmt'])}")
    print(f"WIFI_HIDDEN={'yes' if found.get('hidden') else 'no'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
