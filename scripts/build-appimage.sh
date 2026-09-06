#!/usr/bin/env bash
# Repackage OpenAI's official ChatGPT Linux amd64 .deb as a thin AppImage.
# Payload is the official Electron tree; GTK/NSS/Mesa come from the host.
# Successful builds print only the AppImage path on stdout; everything else is stderr.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REPO_BASE="${CHATGPT_REPO_BASE:-https://persistent.oaistatic.com/codex-app-prod/linux/deb}"
PACKAGES_URL="${CHATGPT_PACKAGES_URL:-$REPO_BASE/dists/stable/main/binary-amd64/Packages}"
ROLLING_DEB_URL="${CHATGPT_ROLLING_DEB_URL:-$REPO_BASE/latest/chatgpt_amd64.deb}"
APPIMAGETOOL_URL="${APPIMAGETOOL_URL:-https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage}"

CACHE_DIR="${CACHE_DIR:-$ROOT/.cache}"
WORK_DIR="${WORK_DIR:-$ROOT/build}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/dist}"

APPDIR=""
EXTRACT_DIR=""
APPIMAGE_PATH=""
DEB_PATH=""
DEB_URL=""
DEB_VERSION=""
DEB_SHA256=""
USE_ROLLING_URL=0

usage() {
  cat <<'EOF'
Usage: scripts/build-appimage.sh [options]

Download the official OpenAI ChatGPT amd64 .deb and repackage it as a thin
AppImage (official Electron tree + desktop/icons + AppRun; host libraries):
  dist/ChatGPT-<version>-x86_64.AppImage

Options:
  --deb PATH         Use a local .deb instead of downloading
  --version VER      Download chatgpt_<VER>_amd64.deb from the versioned pool
  --latest-url       Download the mutable rolling URL (latest/chatgpt_amd64.deb)
  --output-dir DIR   Where to write the AppImage (default: dist/)
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
  for cmd in curl dpkg-deb sha256sum file install desktop-file-validate mksquashfs awk; do
    need_cmd "$cmd"
  done
  [ -f "$ROOT/packaging/AppRun" ] || die "missing $ROOT/packaging/AppRun"
}

setup_dirs() {
  mkdir -p "$CACHE_DIR" "$WORK_DIR" "$OUTPUT_DIR"
  CACHE_DIR="$(cd "$CACHE_DIR" && pwd)"
  WORK_DIR="$(cd "$WORK_DIR" && pwd)"
  OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
  APPDIR="$WORK_DIR/ChatGPT.AppDir"
  EXTRACT_DIR="$WORK_DIR/deb-extract"
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
  local at="$CACHE_DIR/appimagetool-x86_64.AppImage"
  [ -f "$at" ] || download "$APPIMAGETOOL_URL" "$at"
  chmod +x "$at"
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

  # Official launcher symlink (usr/bin/chatgpt -> ../lib/chatgpt/codex-launcher).
  if [ -e "$EXTRACT_DIR/usr/bin/chatgpt" ]; then
    cp -a "$EXTRACT_DIR/usr/bin/chatgpt" "$APPDIR/usr/bin/chatgpt"
  else
    cat >"$APPDIR/usr/bin/chatgpt" <<'WRAP'
#!/bin/sh
exec "$(dirname "$(readlink -f "$0")")/../lib/chatgpt/ChatGPT" "$@"
WRAP
    chmod 0755 "$APPDIR/usr/bin/chatgpt"
  fi

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
  desktop-file-validate "$APPDIR/chatgpt.desktop" >&2 || die "invalid chatgpt.desktop"

  install -m 0755 "$ROOT/packaging/AppRun" "$APPDIR/AppRun"
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
  pack_appimage
  smoke_check
  log "AppImage ready:"
  printf '%s\n' "$APPIMAGE_PATH"
}

main "$@"
