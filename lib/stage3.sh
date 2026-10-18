# shellcheck shell=bash
# Download, verify (OpenPGP) and extract the stage3 tarball.

fetch() { # url dest
  if have curl; then curl -fL --retry 3 -sS -o "$2" "$1"; else wget -q -O "$2" "$1"; fi
}
fetch_stdout() {
  if have curl; then curl -fsSL --retry 3 "$1"; else wget -q -O - "$1"; fi
}

stage3_variant() {
  local v=stage3-amd64
  [[ $G_DESKTOP != none ]] && v+=-desktop
  printf '%s-%s' "$v" "$G_INIT"
}

stage3_verify() {
  local file=$1 key=/usr/share/openpgp-keys/gentoo-release.asc
  if [[ -r $key ]]; then
    export GNUPGHOME="$RUNDIR/gnupg"
    mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"
    gpg --batch --quiet --import "$key"
    if gpg --batch --verify "$file.asc" "$file"; then echo "Signature OK"; return 0; fi
    echo "Stage3 signature verification FAILED. Not extracting."
    return 1
  fi
  if [[ $G_STAGE3_INSECURE == yes ]]; then
    echo "WARNING: $key not found; skipping verification because G_STAGE3_INSECURE=yes"
    return 0
  fi
  echo "The Gentoo release key ($key) isn't on this medium, so the stage3 can't be verified."
  echo "Boot an official Gentoo ISO, or set G_STAGE3_INSECURE=yes in an answers file to override."
  return 1
}

stage3_install() {
  local variant base latest path file
  variant=$(stage3_variant)
  base="${G_MIRROR%/}/releases/amd64/autobuilds"
  if [[ $DRYRUN == 1 ]]; then
    echo "[dry-run] would fetch $base/latest-$variant.txt, download, verify and extract into $TARGET"
    return 0
  fi
  msg "Looking up the latest $variant"
  latest=$(fetch_stdout "$base/latest-$variant.txt")
  path=$(awk -v v="$variant" '$1 ~ ("/" v "-[0-9TZ]+\\.tar\\.xz$") {print $1; exit}' <<<"$latest")
  if [[ -z $path ]]; then echo "No stage3 listed in latest-$variant.txt"; return 1; fi
  file="$TARGET/${path##*/}"
  msg "Downloading $path"
  fetch "$base/$path" "$file"
  fetch "$base/$path.asc" "$file.asc"
  stage3_verify "$file"
  msg "Extracting"
  tar xpf "$file" --xattrs-include='*.*' --numeric-owner -C "$TARGET"
  rm -f "$file" "$file.asc"
  echo "Stage3 extracted."
}
