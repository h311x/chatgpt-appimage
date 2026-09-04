#!/usr/bin/env bash
# Repackage OpenAI's official ChatGPT Linux amd64 .deb as a self-contained AppImage.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REPO_BASE="${CHATGPT_REPO_BASE:-https://persistent.oaistatic.com/codex-app-prod/linux/deb}"
PACKAGES_URL="${CHATGPT_PACKAGES_URL:-$REPO_BASE/dists/stable/main/binary-amd64/Packages}"
ROLLING_DEB_URL="${CHATGPT_ROLLING_DEB_URL:-$REPO_BASE/latest/chatgpt_amd64.deb}"

LINUXDEPLOY_VERSION="${LINUXDEPLOY_VERSION:-1-alpha-20251107-1}"
LINUXDEPLOY_URL="${LINUXDEPLOY_URL:-https://github.com/linuxdeploy/linuxdeploy/releases/download/${LINUXDEPLOY_VERSION}/linuxdeploy-x86_64.AppImage}"
APPIMAGETOOL_URL="${APPIMAGETOOL_URL:-https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage}"
GTK_PLUGIN_URL="${GTK_PLUGIN_URL:-https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/1ee2a937551bac53c6bf47f8123eb4af7c693b91/linuxdeploy-plugin-gtk.sh}"

CACHE_DIR="${CACHE_DIR:-$ROOT/.cache}"
WORK_DIR="${WORK_DIR:-$ROOT/build}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"

APPDIR="$WORK_DIR/ChatGPT.AppDir"
EXTRACT_DIR="$WORK_DIR/deb-extract"
DEB_PATH=""
DEB_URL=""
DEB_VERSION=""
DEB_SHA256=""
SKIP_GTK_PLUGIN=0
USE_ROLLING_URL=0

usage() {
  cat <<'EOF'
Usage: scripts/build-appimage.sh [options]

Download the official OpenAI ChatGPT amd64 .deb and repackage it as:
  dist/ChatGPT-<version>-x86_64.AppImage

Options:
  --deb PATH         Use a local .deb instead of downloading
  --version VER      Download chatgpt_<VER>_amd64.deb from the versioned pool
  --latest-url       Download the mutable rolling URL (latest/chatgpt_amd64.deb)
  --output-dir DIR   Where to write the AppImage (default: dist/)
  --skip-gtk-plugin  Bundle ELF deps only; skip linuxdeploy-plugin-gtk
  -h, --help         Show this help

Environment:
  CHATGPT_DEB        Same as --deb
  CHATGPT_VERSION    Same as --version
  CACHE_DIR WORK_DIR OUTPUT_DIR
EOF
}

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --deb)
        DEB_PATH="${2:-}"
        [ -n "$DEB_PATH" ] || die "--deb requires a path"
        shift 2
        ;;
      --version)
        DEB_VERSION="${2:-}"
        [ -n "$DEB_VERSION" ] || die "--version requires a value"
        shift 2
        ;;
      --latest-url)
        USE_ROLLING_URL=1
        shift
        ;;
      --output-dir)
        OUTPUT_DIR="${2:-}"
        [ -n "$OUTPUT_DIR" ] || die "--output-dir requires a path"
        shift 2
        ;;
      --skip-gtk-plugin)
        SKIP_GTK_PLUGIN=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done

  if [ -z "$DEB_PATH" ] && [ -n "${CHATGPT_DEB:-}" ]; then
    DEB_PATH="$CHATGPT_DEB"
  fi
  if [ -z "$DEB_VERSION" ] && [ -n "${CHATGPT_VERSION:-}" ]; then
    DEB_VERSION="$CHATGPT_VERSION"
  fi
}

check_host() {
  [ "$(uname -s)" = Linux ] || die "Linux is required"
  [ "$(uname -m)" = x86_64 ] || die "v1 only supports amd64/x86_64 (host is $(uname -m))"
  need_cmd curl
  need_cmd dpkg-deb
  need_cmd sha256sum
  need_cmd file
  need_cmd install
  need_cmd desktop-file-validate
}

download() {
  local url="$1" dest="$2"
  log "Downloading $url"
  mkdir -p "$(dirname "$dest")"
  curl -fL --retry 4 --retry-delay 4 --progress-bar -o "$dest" "$url"
}

sha256_of() {
  sha256sum "$1" | awk '{print $1}'
}

# Parse the chatgpt stanza out of the APT Packages index.
packages_field() {
  local field="$1"
  awk -v field="$field" '
    $0 == "Package: chatgpt" { in_pkg=1; next }
    in_pkg && $0 == "" { exit }
    in_pkg && index($0, field ": ") == 1 {
      print substr($0, length(field) + 3)
      exit
    }
  '
}

resolve_from_packages() {
  local index="$CACHE_DIR/Packages"
  download "$PACKAGES_URL" "$index"
  local version filename sha size
  version="$(packages_field Version <"$index")"
  filename="$(packages_field Filename <"$index")"
  sha="$(packages_field SHA256 <"$index")"
  size="$(packages_field Size <"$index")"
  [ -n "$version" ] && [ -n "$filename" ] && [ -n "$sha" ] || die "failed to parse chatgpt stanza from Packages index"
  DEB_VERSION="$version"
  DEB_SHA256="$sha"
  DEB_URL="$REPO_BASE/$filename"
  log "Packages index: chatgpt $DEB_VERSION (${size:-?} bytes, sha256 ${DEB_SHA256:0:12}…)"
}

ensure_deb() {
  mkdir -p "$CACHE_DIR" "$WORK_DIR" "$OUTPUT_DIR"

  if [ -n "$DEB_PATH" ]; then
    [ -f "$DEB_PATH" ] || die "deb not found: $DEB_PATH"
    DEB_PATH="$(readlink -f "$DEB_PATH")"
    DEB_VERSION="$(dpkg-deb -f "$DEB_PATH" Version)"
    log "Using local deb: $DEB_PATH ($DEB_VERSION)"
    return
  fi

  local url dest
  dest="$CACHE_DIR/chatgpt_${DEB_VERSION:-rolling}_amd64.deb"

  if [ "$USE_ROLLING_URL" -eq 1 ]; then
    url="$ROLLING_DEB_URL"
    dest="$CACHE_DIR/chatgpt_amd64.deb"
    download "$url" "$dest"
    DEB_PATH="$dest"
    DEB_VERSION="$(dpkg-deb -f "$DEB_PATH" Version)"
    log "Rolling deb version: $DEB_VERSION"
    return
  fi

  if [ -n "$DEB_VERSION" ]; then
    url="$REPO_BASE/pool/main/c/chatgpt/chatgpt_${DEB_VERSION}_amd64.deb"
    dest="$CACHE_DIR/chatgpt_${DEB_VERSION}_amd64.deb"
    # Prefer SHA256 from Packages when the requested version is the current one.
    local index="$CACHE_DIR/Packages"
    if download "$PACKAGES_URL" "$index"; then
      local indexed
      indexed="$(packages_field Version <"$index")"
      if [ "$indexed" = "$DEB_VERSION" ]; then
        DEB_SHA256="$(packages_field SHA256 <"$index")"
      fi
    fi
  else
    # Must not run this in a subshell — it sets DEB_VERSION / DEB_SHA256 / DEB_URL.
    resolve_from_packages
    url="$DEB_URL"
    dest="$CACHE_DIR/chatgpt_${DEB_VERSION}_amd64.deb"
  fi

  if [ -f "$dest" ] && [ -n "$DEB_SHA256" ]; then
    if [ "$(sha256_of "$dest")" = "$DEB_SHA256" ]; then
      log "Reusing cached deb $dest"
      DEB_PATH="$dest"
      return
    fi
    log "Cached deb checksum mismatch; re-downloading"
  fi

  download "$url" "$dest"
  DEB_PATH="$dest"
  DEB_VERSION="$(dpkg-deb -f "$DEB_PATH" Version)"
  if [ -n "$DEB_SHA256" ]; then
    local got
    got="$(sha256_of "$DEB_PATH")"
    [ "$got" = "$DEB_SHA256" ] || die "SHA256 mismatch for $DEB_PATH (expected $DEB_SHA256, got $got)"
    log "Verified SHA256 $DEB_SHA256"
  fi
}

ensure_tools() {
  local ld="$CACHE_DIR/linuxdeploy-x86_64.AppImage"
  local at="$CACHE_DIR/appimagetool-x86_64.AppImage"
  local gtk="$CACHE_DIR/linuxdeploy-plugin-gtk.sh"

  [ -x "$ld" ] || download "$LINUXDEPLOY_URL" "$ld"
  [ -x "$at" ] || download "$APPIMAGETOOL_URL" "$at"
  chmod +x "$ld" "$at"

  if [ "$SKIP_GTK_PLUGIN" -eq 0 ]; then
    [ -f "$gtk" ] || download "$GTK_PLUGIN_URL" "$gtk"
    chmod +x "$gtk"
    # linuxdeploy finds linuxdeploy-plugin-*.sh on PATH.
    export PATH="$CACHE_DIR:$PATH"
  fi
}

extract_deb() {
  log "Extracting $(basename "$DEB_PATH")"
  rm -rf "$EXTRACT_DIR"
  mkdir -p "$EXTRACT_DIR"
  dpkg-deb -x "$DEB_PATH" "$EXTRACT_DIR"

  local arch
  arch="$(dpkg-deb -f "$DEB_PATH" Architecture)"
  [ "$arch" = amd64 ] || die "expected amd64 deb, got $arch"

  [ -x "$EXTRACT_DIR/usr/lib/chatgpt/ChatGPT" ] || die "deb is missing usr/lib/chatgpt/ChatGPT"
  [ -f "$EXTRACT_DIR/usr/share/applications/chatgpt.desktop" ] || die "deb is missing chatgpt.desktop"
  [ -f "$EXTRACT_DIR/usr/share/pixmaps/chatgpt.png" ] || die "deb is missing chatgpt.png"
}

stage_appdir() {
  log "Staging AppDir at $APPDIR"
  rm -rf "$APPDIR"
  mkdir -p \
    "$APPDIR/usr/lib" \
    "$APPDIR/usr/bin" \
    "$APPDIR/usr/share/applications" \
    "$APPDIR/usr/share/icons/hicolor/1024x1024/apps" \
    "$APPDIR/usr/share/pixmaps" \
    "$APPDIR/usr/share/doc/chatgpt"

  # Keep the official Electron layout: Chromium loads resources next to the binary.
  cp -a "$EXTRACT_DIR/usr/lib/chatgpt" "$APPDIR/usr/lib/chatgpt"

  if [ -f "$EXTRACT_DIR/usr/share/doc/chatgpt/copyright" ]; then
    cp -a "$EXTRACT_DIR/usr/share/doc/chatgpt/copyright" "$APPDIR/usr/share/doc/chatgpt/copyright"
  fi

  # Wrapper so Exec=chatgpt matches the desktop file without duplicating the 300MB ELF.
  cat >"$APPDIR/usr/bin/chatgpt" <<'WRAP'
#!/bin/sh
exec "$(dirname "$(readlink -f "$0")")/../lib/chatgpt/ChatGPT" "$@"
WRAP
  chmod 0755 "$APPDIR/usr/bin/chatgpt"

  local icon="$EXTRACT_DIR/usr/share/pixmaps/chatgpt.png"
  install -m 0644 "$icon" "$APPDIR/chatgpt.png"
  install -m 0644 "$icon" "$APPDIR/.DirIcon"
  install -m 0644 "$icon" "$APPDIR/usr/share/pixmaps/chatgpt.png"
  install -m 0644 "$icon" "$APPDIR/usr/share/icons/hicolor/1024x1024/apps/chatgpt.png"

  # Official desktop file plus AppImage/KDE extras. Keep MimeType as shipped.
  awk -v ver="$DEB_VERSION" '
    BEGIN { have_wm=0 }
    /^StartupWMClass=/ { have_wm=1 }
    { print }
    END {
      if (!have_wm) print "StartupWMClass=ChatGPT"
      print "X-AppImage-Name=ChatGPT"
      print "X-AppImage-Version=" ver
      print "X-AppImage-Arch=x86_64"
    }
  ' "$EXTRACT_DIR/usr/share/applications/chatgpt.desktop" >"$APPDIR/chatgpt.desktop"
  chmod 0644 "$APPDIR/chatgpt.desktop"
  cp -a "$APPDIR/chatgpt.desktop" "$APPDIR/usr/share/applications/chatgpt.desktop"
  desktop-file-validate "$APPDIR/chatgpt.desktop"

  install -m 0755 "$ROOT/packaging/AppRun" "$APPDIR/AppRun"
}

resolve_lib() {
  local name="$1"
  local path
  path="$(ldconfig -p 2>/dev/null | awk -v n="$name" '$1 == n { print $NF; exit }')"
  if [ -n "$path" ] && [ -e "$path" ]; then
    printf '%s\n' "$path"
    return 0
  fi
  return 1
}

linuxdeploy_library_args() {
  # These are Depends / typical Electron dlopen targets, not always in NEEDED.
  local names=(
    libnotify.so.4
    libXss.so.1
    libXtst.so.6
    libxcb-dri3.so.0
    libusb-1.0.so.0
    libsecret-1.so.0
    libxshmfence.so.1
    libnss3.so
    libnssutil3.so
    libsmime3.so
    libnspr4.so
    libplc4.so
    libplds4.so
    libsoftokn3.so
    libfreebl3.so
    libfreeblpriv3.so
    libnssckbi.so
  )
  local name path
  for name in "${names[@]}"; do
    if path="$(resolve_lib "$name")"; then
      printf -- '--library=%s\n' "$path"
    else
      log "note: optional library not on host: $name"
    fi
  done
}

copy_nss_checksums() {
  local lib dest
  mkdir -p "$APPDIR/usr/lib"
  for lib in libsoftokn3 libfreebl3 libfreeblpriv3 libnssdbm3; do
    if [ -f "/usr/lib/x86_64-linux-gnu/${lib}.chk" ]; then
      dest="$APPDIR/usr/lib/${lib}.chk"
      cp -a "/usr/lib/x86_64-linux-gnu/${lib}.chk" "$dest"
    fi
  done
}

# linuxdeploy walks every ELF already in the AppDir. Chromium's optional Qt
# shims NEEDED Qt (not a .deb Depends), and unused musl .node prebuilds NEEDED
# musl. Park them for the bundling pass, then put them back unchanged.
PARK_DIR="$WORK_DIR/parked-elf"
PARK_MANIFEST="$WORK_DIR/parked-elf.manifest"

park_unresolvable_elfs() {
  rm -rf "$PARK_DIR"
  mkdir -p "$PARK_DIR"
  : >"$PARK_MANIFEST"

  park_one() {
    local src="$1"
    local rel dest
    [ -e "$src" ] || return 0
    rel="${src#"$APPDIR"/}"
    dest="$PARK_DIR/$rel"
    mkdir -p "$(dirname "$dest")"
    mv "$src" "$dest"
    printf '%s\n' "$rel" >>"$PARK_MANIFEST"
  }

  park_one "$APPDIR/usr/lib/chatgpt/libqt5_shim.so"
  park_one "$APPDIR/usr/lib/chatgpt/libqt6_shim.so"

  local src
  while IFS= read -r src; do
    park_one "$src"
  done < <(find "$APPDIR" -type f \( -name '*musl*.node' -o -name '*musl*.so*' \) || true)

  if [ -s "$PARK_MANIFEST" ]; then
    log "Parked $(wc -l <"$PARK_MANIFEST") ELF files linuxdeploy cannot resolve (Qt shims / musl prebuilds)"
  fi
}

restore_parked_elfs() {
  [ -f "$PARK_MANIFEST" ] || return 0
  local rel
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    mkdir -p "$APPDIR/$(dirname "$rel")"
    mv "$PARK_DIR/$rel" "$APPDIR/$rel"
  done <"$PARK_MANIFEST"
}

bundle_libraries() {
  log "Bundling shared libraries with linuxdeploy"
  export APPIMAGE_EXTRACT_AND_RUN=1
  export NO_STRIP=1
  export DISABLE_COPYRIGHT_FILES_DEPLOYMENT=1
  export LINUXDEPLOY="$CACHE_DIR/linuxdeploy-x86_64.AppImage"
  export PATH="$CACHE_DIR:$PATH"
  export DEPLOY_GTK_VERSION=3

  park_unresolvable_elfs

  local -a args
  args=(
    --appdir "$APPDIR"
    --executable "$APPDIR/usr/lib/chatgpt/ChatGPT"
    --executable "$APPDIR/usr/lib/chatgpt/browser_crashpad_handler"
    --desktop-file "$APPDIR/chatgpt.desktop"
    --icon-file "$APPDIR/chatgpt.png"
    --icon-filename chatgpt
    --custom-apprun "$ROOT/packaging/AppRun"
    --exclude-library 'libQt5*'
    --exclude-library 'libQt6*'
  )

  local extra
  while IFS= read -r extra; do
    [ -n "$extra" ] || continue
    args+=("$extra")
  done < <(linuxdeploy_library_args)

  if [ "$SKIP_GTK_PLUGIN" -eq 0 ]; then
    if ! command -v pkg-config >/dev/null || ! pkg-config --exists gtk+-3.0; then
      die "linuxdeploy-plugin-gtk needs pkg-config and GTK 3 development files (libgtk-3-dev). Re-run with --skip-gtk-plugin to bundle ELF NEEDED libs only."
    fi
    args+=(--plugin gtk)
  fi

  "$LINUXDEPLOY" "${args[@]}"
  restore_parked_elfs
  copy_nss_checksums
  install -m 0755 "$ROOT/packaging/AppRun" "$APPDIR/AppRun"
}

glibc_floor() {
  local f max=""
  local -a targets=("$APPDIR/usr/lib/chatgpt/ChatGPT")
  shopt -s nullglob
  targets+=("$APPDIR"/usr/lib/*.so*)
  shopt -u nullglob
  for f in "${targets[@]}"; do
    [ -f "$f" ] || continue
    file -b "$f" | grep -q '^ELF' || continue
    local v
    v="$(objdump -T "$f" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -V | tail -1 || true)"
    if [ -n "$v" ] && { [ -z "$max" ] || [ "$(printf '%s\n%s\n' "$max" "$v" | sort -V | tail -1)" = "$v" ]; }; then
      max="$v"
    fi
  done
  printf '%s\n' "${max:-unknown}"
}

pack_appimage() {
  local out="$OUTPUT_DIR/ChatGPT-${DEB_VERSION}-x86_64.AppImage"
  log "Packing $out"
  rm -f "$out"
  export APPIMAGE_EXTRACT_AND_RUN=1
  export ARCH=x86_64
  export VERSION="$DEB_VERSION"
  "$CACHE_DIR/appimagetool-x86_64.AppImage" --no-appstream "$APPDIR" "$out"
  chmod 0755 "$out"
  printf '%s\n' "$out"
}

smoke_check() {
  local out="$1"
  log "Smoke-testing $out"
  [ -f "$out" ] || die "AppImage not created: $out"
  [ -x "$out" ] || die "AppImage is not executable: $out"
  file "$out" | grep -q 'ELF 64-bit' || die "AppImage is not an ELF 64-bit file: $(file "$out")"

  export APPIMAGE_EXTRACT_AND_RUN=1
  "$out" --appimage-help >/dev/null
  local offset
  offset="$("$out" --appimage-offset)"
  [ -n "$offset" ] || die "--appimage-offset produced no output"

  log "file: $(file -b "$out")"
  log "size: $(du -h "$out" | awk '{print $1}')"
  log "appimage-offset: $offset"
  log "glibc floor (bundled libs + ChatGPT ELF): $(glibc_floor)"
  log "This VM is headless — not launching the GUI. On a desktop: $out"
}

main() {
  parse_args "$@"
  check_host
  ensure_deb
  ensure_tools
  extract_deb
  stage_appdir
  bundle_libraries
  local out
  out="$(pack_appimage)"
  smoke_check "$out"
  log "AppImage ready:"
  printf '%s\n' "$out"
}

main "$@"
