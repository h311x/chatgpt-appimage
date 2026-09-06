#!/usr/bin/env bash
# Repackage OpenAI's official ChatGPT Linux amd64 .deb as a self-contained AppImage.
# Successful builds print only the AppImage path on stdout; everything else is stderr.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REPO_BASE="${CHATGPT_REPO_BASE:-https://persistent.oaistatic.com/codex-app-prod/linux/deb}"
PACKAGES_URL="${CHATGPT_PACKAGES_URL:-$REPO_BASE/dists/stable/main/binary-amd64/Packages}"
ROLLING_DEB_URL="${CHATGPT_ROLLING_DEB_URL:-$REPO_BASE/latest/chatgpt_amd64.deb}"

LINUXDEPLOY_VERSION="${LINUXDEPLOY_VERSION:-1-alpha-20251107-1}"
LINUXDEPLOY_URL="${LINUXDEPLOY_URL:-https://github.com/linuxdeploy/linuxdeploy/releases/download/${LINUXDEPLOY_VERSION}/linuxdeploy-x86_64.AppImage}"
APPIMAGETOOL_URL="${APPIMAGETOOL_URL:-https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage}"
# Pinned blob, not linuxdeploy-plugin-gtk/master — master has moved and 404'd before.
GTK_PLUGIN_URL="${GTK_PLUGIN_URL:-https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/1ee2a937551bac53c6bf47f8123eb4af7c693b91/linuxdeploy-plugin-gtk.sh}"

CACHE_DIR="${CACHE_DIR:-$ROOT/.cache}"
WORK_DIR="${WORK_DIR:-$ROOT/build}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"

APPDIR=""
EXTRACT_DIR=""
PARK_DIR=""
APPIMAGE_PATH=""
DEB_PATH=""
DEB_URL=""
DEB_VERSION=""
DEB_SHA256=""
SKIP_GTK_PLUGIN=0
USE_ROLLING_URL=0

# linuxdeploy walks every ELF in AppDir. Park Qt shims (NEEDED Qt, not a Depends)
# and resources/ (musl/static native modules) so it cannot rewrite them.
PARK_RELS=(usr/lib/chatgpt/libqt5_shim.so usr/lib/chatgpt/libqt6_shim.so usr/lib/chatgpt/resources)

# Electron dlopen targets — not always in DT_NEEDED.
EXTRA_LIBS=(
  libnotify.so.4 libXss.so.1 libXtst.so.6 libxcb-dri3.so.0
  libusb-1.0.so.0 libsecret-1.so.0 libxshmfence.so.1
  libnss3.so libnssutil3.so libsmime3.so libnspr4.so libplc4.so libplds4.so
  libsoftokn3.so libfreebl3.so libfreeblpriv3.so libnssckbi.so libnssdbm3.so
)

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
  local cmd
  for cmd in curl dpkg-deb sha256sum file install desktop-file-validate python3 mksquashfs awk ldconfig; do
    need_cmd "$cmd"
  done
  python3 - <<'PY' >&2 || die "need python3-gi and gir1.2-gdkpixbuf-2.0 (to resize the 1024px icon)"
import gi
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf
PY
  if [ "$SKIP_GTK_PLUGIN" -eq 0 ]; then
    need_cmd pkg-config
    pkg-config --exists gtk+-3.0 || die "linuxdeploy-plugin-gtk needs pkg-config and GTK 3 development files (libgtk-3-dev). Re-run with --skip-gtk-plugin to bundle ELF NEEDED libs only."
  fi
}

setup_dirs() {
  mkdir -p "$CACHE_DIR" "$WORK_DIR" "$OUTPUT_DIR"
  CACHE_DIR="$(cd "$CACHE_DIR" && pwd)"
  WORK_DIR="$(cd "$WORK_DIR" && pwd)"
  OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
  APPDIR="$WORK_DIR/ChatGPT.AppDir"
  EXTRACT_DIR="$WORK_DIR/deb-extract"
  PARK_DIR="$WORK_DIR/parked-payload"
}

download() {
  local url="$1" dest="$2"
  local tmp="${dest}.part"
  log "Downloading $url"
  mkdir -p "$(dirname "$dest")"
  if ! curl -fL --retry 4 --retry-delay 4 --progress-bar -o "$tmp" "$url"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$dest"
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
  local version filename sha size
  download "$PACKAGES_URL" "$index" || die "failed to download Packages index"
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
    dest="$CACHE_DIR/chatgpt_amd64.deb"
    download "$ROLLING_DEB_URL" "$dest"
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
    else
      log "note: Packages index unavailable; building $DEB_VERSION without SHA256"
    fi
  else
    resolve_from_packages
    url="$DEB_URL"
    dest="$CACHE_DIR/chatgpt_${DEB_VERSION}_amd64.deb"
  fi

  if [ -f "$dest" ]; then
    if [ -n "$DEB_SHA256" ] && [ "$(sha256_of "$dest")" = "$DEB_SHA256" ]; then
      log "Reusing cached deb $dest"
      DEB_PATH="$dest"
      return
    fi
    if [ -z "$DEB_SHA256" ] && [ "$(dpkg-deb -f "$dest" Version 2>/dev/null || true)" = "$DEB_VERSION" ]; then
      log "Reusing cached deb $dest (no Packages SHA256 for this version)"
      DEB_PATH="$dest"
      return
    fi
    if [ -n "$DEB_SHA256" ]; then
      log "Cached deb checksum mismatch; re-downloading"
    fi
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

  [ -f "$ld" ] || download "$LINUXDEPLOY_URL" "$ld"
  [ -f "$at" ] || download "$APPIMAGETOOL_URL" "$at"
  chmod +x "$ld" "$at"

  if [ "$SKIP_GTK_PLUGIN" -eq 0 ]; then
    [ -f "$gtk" ] || download "$GTK_PLUGIN_URL" "$gtk"
    chmod +x "$gtk"
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

resize_png() {
  local src="$1" dest="$2" size="$3"
  python3 - "$src" "$dest" "$size" <<'PY'
import sys
import gi
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf

src, dest, size_s = sys.argv[1], sys.argv[2], sys.argv[3]
size = int(size_s)
pb = GdkPixbuf.Pixbuf.new_from_file(src)
pb = pb.scale_simple(size, size, GdkPixbuf.InterpType.BILINEAR)
pb.savev(dest, "png", [], [])
PY
}

stage_appdir() {
  log "Staging AppDir at $APPDIR"
  rm -rf "$APPDIR"
  mkdir -p \
    "$APPDIR/usr/lib" \
    "$APPDIR/usr/bin" \
    "$APPDIR/usr/share/applications" \
    "$APPDIR/usr/share/icons/hicolor/256x256/apps" \
    "$APPDIR/usr/share/icons/hicolor/512x512/apps" \
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
  # linuxdeploy only accepts a fixed set of raster sizes; the official pixmap is 1024².
  resize_png "$icon" "$APPDIR/chatgpt.png" 512
  install -m 0644 "$APPDIR/chatgpt.png" "$APPDIR/.DirIcon"
  install -m 0644 "$APPDIR/chatgpt.png" "$APPDIR/usr/share/icons/hicolor/512x512/apps/chatgpt.png"
  install -m 0644 "$icon" "$APPDIR/usr/share/pixmaps/chatgpt.png"
  install -m 0644 "$icon" "$APPDIR/usr/share/icons/hicolor/1024x1024/apps/chatgpt.png"
  resize_png "$icon" "$APPDIR/usr/share/icons/hicolor/256x256/apps/chatgpt.png" 256

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
  desktop-file-validate "$APPDIR/chatgpt.desktop" >&2 || die "invalid chatgpt.desktop"
}

resolve_lib() {
  local name="$1" path
  path="$(ldconfig -p 2>/dev/null | awk -v n="$name" '$1 == n { print $NF; exit }')"
  [ -n "$path" ] && [ -e "$path" ] || return 1
  printf '%s\n' "$path"
}

park_payload() {
  rm -rf "$PARK_DIR"
  mkdir -p "$PARK_DIR"
  local rel src dest
  for rel in "${PARK_RELS[@]}"; do
    src="$APPDIR/$rel"
    [ -e "$src" ] || continue
    dest="$PARK_DIR/$rel"
    mkdir -p "$(dirname "$dest")"
    mv "$src" "$dest"
  done
  log "Parked Qt shims / resources so linuxdeploy cannot rewrite them"
}

restore_payload() {
  local rel
  for rel in "${PARK_RELS[@]}"; do
    [ -e "$PARK_DIR/$rel" ] || continue
    mkdir -p "$APPDIR/$(dirname "$rel")"
    mv "$PARK_DIR/$rel" "$APPDIR/$rel"
  done
}

copy_nss_checksums() {
  local lib so chk
  mkdir -p "$APPDIR/usr/lib"
  for lib in libsoftokn3 libfreebl3 libfreeblpriv3 libnssdbm3; do
    [ -e "$APPDIR/usr/lib/${lib}.so" ] || continue
    so="$(resolve_lib "${lib}.so" || true)"
    [ -n "$so" ] || continue
    chk="$(dirname "$so")/${lib}.chk"
    [ -f "$chk" ] || continue
    cp -a "$chk" "$APPDIR/usr/lib/${lib}.chk"
  done
}

bundle_libraries() {
  log "Bundling shared libraries with linuxdeploy"
  export APPIMAGE_EXTRACT_AND_RUN=1
  export NO_STRIP=1
  export DISABLE_COPYRIGHT_FILES_DEPLOYMENT=1
  export LINUXDEPLOY="$CACHE_DIR/linuxdeploy-x86_64.AppImage"
  export DEPLOY_GTK_VERSION=3
  # linuxdeploy finds linuxdeploy-plugin-*.sh on PATH.
  export PATH="$CACHE_DIR:$PATH"

  local -a ld_args=(
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

  local name path
  for name in "${EXTRA_LIBS[@]}"; do
    if path="$(resolve_lib "$name")"; then
      ld_args+=("--library=$path")
    else
      log "note: optional library not on host: $name"
    fi
  done

  if [ "$SKIP_GTK_PLUGIN" -eq 0 ]; then
    ld_args+=(--plugin gtk)
  fi

  park_payload
  trap restore_payload EXIT
  "$LINUXDEPLOY" "${ld_args[@]}" >&2 || die "linuxdeploy failed"
  trap - EXIT
  restore_payload

  copy_nss_checksums
  install -m 0755 "$ROOT/packaging/AppRun" "$APPDIR/AppRun"
}

glibc_floor() {
  command -v objdump >/dev/null 2>&1 || { printf '%s\n' unknown; return 0; }
  local f max="" v
  shopt -s nullglob
  local -a targets=("$APPDIR/usr/lib/chatgpt/ChatGPT" "$APPDIR"/usr/lib/*.so*)
  shopt -u nullglob
  for f in "${targets[@]}"; do
    [ -f "$f" ] || continue
    file -b "$f" 2>/dev/null | grep -q '^ELF' || continue
    v="$(objdump -T "$f" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -V | tail -1 || true)"
    if [ -n "$v" ] && { [ -z "$max" ] || [ "$(printf '%s\n%s\n' "$max" "$v" | sort -V | tail -1)" = "$v" ]; }; then
      max="$v"
    fi
  done
  printf '%s\n' "${max:-unknown}"
}

pack_appimage() {
  APPIMAGE_PATH="$OUTPUT_DIR/ChatGPT-${DEB_VERSION}-x86_64.AppImage"
  log "Packing $APPIMAGE_PATH"
  rm -f "$APPIMAGE_PATH"
  export APPIMAGE_EXTRACT_AND_RUN=1
  export ARCH=x86_64
  export VERSION="$DEB_VERSION"
  "$CACHE_DIR/appimagetool-x86_64.AppImage" --no-appstream "$APPDIR" "$APPIMAGE_PATH" >&2
  chmod 0755 "$APPIMAGE_PATH"
}

smoke_check() {
  local out="$APPIMAGE_PATH"
  log "Smoke-testing $out"
  [ -f "$out" ] || die "AppImage not created: $out"
  [ -x "$out" ] || die "AppImage is not executable: $out"
  file "$out" | grep -q 'ELF 64-bit' || die "AppImage is not an ELF 64-bit file: $(file "$out")"

  export APPIMAGE_EXTRACT_AND_RUN=1
  "$out" --appimage-help >/dev/null 2>&1
  local offset
  offset="$("$out" --appimage-offset)"
  [ -n "$offset" ] || die "--appimage-offset produced no output"

  log "file: $(file -b "$out")"
  log "size: $(du -h "$out" | awk '{print $1}')"
  log "appimage-offset: $offset"
  log "glibc floor (bundled libs + ChatGPT ELF): $(glibc_floor)"

  local reported
  reported="$("$out" --version 2>/dev/null | tail -n 1 | tr -d '\r')"
  if [ "$reported" = "$DEB_VERSION" ]; then
    log "ChatGPT --version: $reported"
  else
    log "note: ChatGPT --version reported '${reported:-<empty>}' (deb version is $DEB_VERSION)"
  fi
  log "CLI smoke passed. GUI launch is not part of this script; on a desktop run: $out"
}

main() {
  parse_args "$@"
  check_host
  setup_dirs
  ensure_deb
  ensure_tools
  extract_deb
  stage_appdir
  bundle_libraries
  pack_appimage
  smoke_check
  log "AppImage ready:"
  printf '%s\n' "$APPIMAGE_PATH"
}

main "$@"
