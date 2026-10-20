#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Read a failed emerge's output and apply the USE flags it asked for.

Handles the two ways Portage reports a missing USE flag:

1. "The following USE changes are necessary to proceed:" followed by lines
   like `>=x11-libs/libxfce4ui-4.20.0 gtk3` (a dependency needs a flag).
2. "The following REQUIRED_USE flag constraints are unsatisfied:" for a
   package whose own flags conflict. Only plain single-flag constraints such
   as `gtk3` or `!qt5` are applied; any-of / exactly-one-of choices are left
   for a person to decide.

Flags are written package-wide (`x11-libs/libxfce4ui gtk3`), never pinned to
a version, and merged into one line per package in the given package.use file.

Usage: use-fix.py EMERGE_OUTPUT PACKAGE_USE_FILE
Exit 0 if new flags were written, 1 if there was nothing (new) to apply.
"""
import re
import sys
from pathlib import Path

ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
FLAG = re.compile(r"^-?[A-Za-z0-9][A-Za-z0-9+_@.-]*$")
# Version format from PMS: 1.2.3b_rc4_p5-r6 (anchored at the end of the name)
PMS_VERSION = re.compile(
    r"-[0-9]+(\.[0-9]+)*[a-z]?((_alpha|_beta|_pre|_rc|_p)[0-9]*)*(-r[0-9]+)?$")

try:
    import portage.dep
    import portage.versions
except ImportError:  # outside a Gentoo system (tests): use the PMS regex
    portage = None


def strip_repo_slot(s):
    s = s.split("::", 1)[0]
    return s.split(":", 1)[0]


def atom_cp(atom):
    """'>=x11-libs/gtk+-3.24.43-r1:3' -> 'x11-libs/gtk+'"""
    if portage:
        try:
            return portage.dep.Atom(atom).cp
        except Exception:
            pass
    s = strip_repo_slot(re.sub(r"^[<>=~!]+", "", atom)).rstrip("*")
    return PMS_VERSION.sub("", s)


def cpv_cp(cpv):
    """'xfce-base/xfce4-meta-4.20::gentoo' -> 'xfce-base/xfce4-meta'"""
    s = strip_repo_slot(cpv)
    if portage:
        split = portage.versions.catpkgsplit(s)
        if split:
            return f"{split[0]}/{split[1]}"
    return PMS_VERSION.sub("", s)


def parse(text):
    """Return {category/package: [flags]} requested by emerge's output."""
    want = {}
    lines = ANSI.sub("", text).splitlines()

    def add(cp, flags):
        if "/" not in cp:
            return
        cur = want.setdefault(cp, [])
        cur.extend(f for f in flags if f not in cur)

    i = 0
    while i < len(lines):
        line = lines[i]
        if "The following USE changes are necessary to proceed" in line:
            i += 1
            while i < len(lines) and lines[i].strip():
                entry = lines[i].strip()
                if not entry.startswith(("#", "(")):
                    parts = entry.split()
                    flags = [f for f in parts[1:] if FLAG.match(f)]
                    if len(parts) > 1 and flags:
                        add(atom_cp(parts[0]), flags)
                i += 1
        elif "The following REQUIRED_USE flag constraints are unsatisfied" in line:
            # The package is on the nearest earlier "- cat/pkg-ver::repo USE=..." line
            pkg = None
            for back in range(i - 1, max(i - 8, -1), -1):
                m = re.match(r"^- (\S+/\S+)", lines[back].strip())
                if m:
                    pkg = cpv_cp(m.group(1))
                    break
            i += 1
            flags = []
            while i < len(lines) and lines[i].strip():
                c = lines[i].strip()
                if re.fullmatch(r"!?[A-Za-z0-9][A-Za-z0-9+_@.-]*", c):
                    flags.append("-" + c[1:] if c.startswith("!") else c)
                else:
                    flags = None  # a choice (any-of, ?? etc.): leave it to a person
                    break
                i += 1
            if pkg and flags:
                add(pkg, flags)
        i += 1
    return want


def read_use_file(path):
    entries = {}
    if path.exists():
        for line in path.read_text().splitlines():
            parts = line.split()
            if parts and not parts[0].startswith("#"):
                entries[parts[0]] = parts[1:]
    return entries


def main():
    out, use_file = Path(sys.argv[1]), Path(sys.argv[2])
    want = parse(out.read_text(errors="replace"))
    entries = read_use_file(use_file)
    changed = []
    for cp, flags in want.items():
        cur = entries.setdefault(cp, [])
        for f in flags:
            opposite = f[1:] if f.startswith("-") else "-" + f
            if f in cur:
                continue
            if opposite in cur:  # flip a flag we set earlier
                cur.remove(opposite)
            cur.append(f)
            changed.append(f"{cp} {f}")
    if not changed:
        return 1
    use_file.parent.mkdir(parents=True, exist_ok=True)
    body = "".join(f"{cp} {' '.join(fl)}\n" for cp, fl in sorted(entries.items()) if fl)
    use_file.write_text(
        "# USE flags added by toboggan because emerge reported them as required.\n"
        "# Package-wide on purpose, so they keep applying after version bumps.\n" + body)
    for c in changed:
        print(f"  added: {c}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
