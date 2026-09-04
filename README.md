# ChatGPT AppImage (unofficial)

Repackage [OpenAI’s official Linux ChatGPT desktop app](https://learn.chatgpt.com/docs/linux/linux-app) into an **amd64 AppImage**. The payload is the real Electron binary from the official `.deb` — not a web wrapper, Flatpak, or root install.

Intended for **SteamOS / Steam Deck Desktop Mode** via [Gear Lever](https://github.com/mijorus/gearlever), and for other distros that do not want Ubuntu/Fedora packages.

This project is **not affiliated with OpenAI**. Redistribution of the official Linux build is in scope for this repo.

## Build

On an amd64 Linux host (Ubuntu 24.04 is what the official app targets; that is also a good bundling host):

```bash
sudo apt-get install -y curl dpkg-dev squashfs-tools desktop-file-utils \
  pkg-config libgtk-3-dev librsvg2-dev libpango1.0-dev libgdk-pixbuf-2.0-dev \
  python3-gi gir1.2-gdkpixbuf-2.0 binutils \
  libnotify4 libnss3 libxss1 libxtst6 libusb-1.0-0 libsecret-1-0

./scripts/build-appimage.sh
```

Logs go to stderr. On success, stdout is a single line — the output path — so it is safe to capture:

```text
dist/ChatGPT-26.901.31953-x86_64.AppImage
```

That name is stable enough for Gear Lever GitHub Releases wildcards later:

```text
https://github.com/h311x/chatgpt-appimage/releases/download/*/ChatGPT-*-x86_64.AppImage
```

GitHub Actions / scheduled releases are **not** in this v1 — build locally (or on a VM), then publish a Release by hand when you want Gear Lever to pick it up.

### Options

| Flag / env | Meaning |
| --- | --- |
| `--deb PATH` / `CHATGPT_DEB` | Use a `.deb` you already downloaded |
| `--version VER` / `CHATGPT_VERSION` | Fetch `chatgpt_<VER>_amd64.deb` from the versioned pool |
| `--latest-url` | Fetch the mutable rolling URL `…/latest/chatgpt_amd64.deb` |
| `--output-dir DIR` / `OUTPUT_DIR` | Where to write the AppImage (default `dist/`) |
| `--skip-gtk-plugin` | Bundle `ldd` deps only; skip GTK modules / pixbuf loaders |

Default download path is the **APT `Packages` index** → versioned pool file + SHA-256, not the rolling `latest/` URL. The rolling file is overwritten in place and breaks checksum pins (see [openai/codex#38457](https://github.com/openai/codex/issues/38457)).

```text
https://persistent.oaistatic.com/codex-app-prod/linux/deb/dists/stable/main/binary-amd64/Packages
https://persistent.oaistatic.com/codex-app-prod/linux/deb/pool/main/c/chatgpt/chatgpt_<version>_amd64.deb
```

Work files land in `.cache/` (tools + debs) and `build/` (AppDir). Both are gitignored.

## What the script does

Inspected layout of the official amd64 `.deb` (v1):

| Path | Role |
| --- | --- |
| `usr/lib/chatgpt/ChatGPT` | Electron / Chromium binary (~300 MB) |
| `usr/lib/chatgpt/codex-launcher` | `exec …/ChatGPT` |
| `usr/bin/chatgpt` | Symlink to that launcher |
| `usr/share/applications/chatgpt.desktop` | Desktop entry (`Exec=chatgpt %U`, `Icon=chatgpt`) |
| `usr/share/pixmaps/chatgpt.png` | 1024×1024 icon |
| `etc/apparmor.d/chatgpt` | **Omitted** from the AppImage (host AppArmor profile) |

Build steps:

1. Resolve and download the official amd64 `.deb` (SHA-256 when the Packages index is used).
2. Extract it and copy `usr/lib/chatgpt/` unchanged into an AppDir (Chromium loads `resources.pak` / locales **next to the ELF**).
3. Install the official `.desktop` + PNG (plus `StartupWMClass=ChatGPT` for KDE). `packaging/AppRun` is passed to linuxdeploy as `--custom-apprun` and reinstalled after bundling.
4. Run [linuxdeploy](https://github.com/linuxdeploy/linuxdeploy) so GTK, NSS, ALSA, and other Ubuntu `.deb` Depends are copied into `usr/lib/` instead of being pulled from apt at runtime. [linuxdeploy-plugin-gtk](https://github.com/linuxdeploy/linuxdeploy-plugin-gtk) (pinned commit, not `master`) adds pixbuf loaders / immodules. Extra Electron `dlopen` libs (`libnotify`, NSS `softokn`/`freebl`/`nssdbm`, `libXss`, `libusb`, …) are passed with `--library`. Qt shims and the `resources/` tree are parked during this pass so linuxdeploy cannot rewrite musl/static ELFs, then restored. glibc, libGL, libdrm, and Vulkan stay on the **host** (GPU drivers).
5. Pack with [appimagetool](https://github.com/AppImage/appimagetool) as `ChatGPT-<deb-version>-x86_64.AppImage`.

`NO_STRIP=1` is set so linuxdeploy does not strip the 300 MB Electron binary.

## SteamOS / Gear Lever notes

- **Desktop Mode** is required for a GUI. Game Mode will not show this windowed Electron app usefully.
- Install [Gear Lever](https://flathub.org/apps/it.mijorus.gearlever), drop the AppImage on it, and integrate. After GitHub Releases exist, set the update URL to `https://github.com/h311x/chatgpt-appimage/releases/download/*/ChatGPT-*-x86_64.AppImage`.
- **FUSE:** type-2 AppImages mount via FUSE (`libfuse2`). SteamOS and some immutable images do not ship it. Gear Lever often extracts AppImages, which avoids FUSE. Otherwise:
  ```bash
  APPIMAGE_EXTRACT_AND_RUN=1 ./ChatGPT-*-x86_64.AppImage
  # or
  ./ChatGPT-*-x86_64.AppImage --appimage-extract-and-run
  ```
- **glibc:** the AppImage does not bundle glibc. The official `.deb` already wants `libc6 >= 2.35`. Libraries bundled from Ubuntu 24.04 currently need **GLIBC_2.38** (the build script prints the floor). Current SteamOS / Bazzite / Arch snapshots are usually new enough; very old Deck images may not be.
- **Sandbox:** the official package has no `chrome-sandbox`. Chromium uses user namespaces. If a host blocks those, start with `--no-sandbox` (last resort).
- **GPU:** Mesa / NVIDIA stay on the host. That is what you want on SteamOS.
- **xdg-open / git:** not bundled. The host’s tools are used for browser links and Codex git features.

## GUI / smoke checks

The build script’s CLI smoke check is: the AppImage exists, is a 64-bit ELF, is executable, `--appimage-help` / `--appimage-offset` work, and `ChatGPT --version` matches the `.deb`. It also prints the glibc symbol floor of the bundled ELFs. It does **not** open the GUI (that would hang a headless build).

On a desktop, run the AppImage directly (needs **libfuse2** / `libfuse.so.2`). This packaging VM’s XFCE session (`DISPLAY=:1`) launched it with a native FUSE mount and showed the official **Sign in to ChatGPT** window — no extra Electron flags.

If FUSE is missing:

```bash
APPIMAGE_EXTRACT_AND_RUN=1 ./dist/ChatGPT-*-x86_64.AppImage
```

## Out of scope (v1)

- GitHub Actions / scheduled builds
- arm64
- Publishing Releases from the build agent
- Cloudflare / static URL redirects

## License

Packaging scripts in this repository are available under the terms you use for the rest of the project.

The AppImage contents include OpenAI’s proprietary ChatGPT desktop application and third-party components (Electron / Chromium). See `usr/share/doc/chatgpt/copyright` inside the `.deb` / AppDir for Electron’s MIT notice, and OpenAI’s product terms for the app itself.
