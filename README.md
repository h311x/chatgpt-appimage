# ChatGPT AppImage (unofficial)

Repackage [OpenAI’s official Linux ChatGPT desktop app](https://learn.chatgpt.com/docs/linux/linux-app) into a **thin amd64 AppImage**. The payload is the real Electron binary from the official `.deb` — not a web wrapper, Flatpak, or root install.

This is a **thin** AppImage: it ships OpenAI’s Electron tree (and desktop/icons) and uses **host** libraries for GTK, NSS, Mesa, and the rest of the `.deb` Depends. That matches the primary target — **SteamOS / Steam Deck Desktop Mode** via [Gear Lever](https://github.com/mijorus/gearlever) — where those libraries are already present. Other distros may need to install missing packages (same set the official `.deb` would pull in).

This project is **not affiliated with OpenAI**. Redistribution of the official Linux build is in scope for this repo.

## Build

On an amd64 Linux host:

```bash
sudo apt-get install -y curl dpkg squashfs-tools desktop-file-utils file zsync binutils

./scripts/build-appimage.sh
```

Logs go to stderr. On success, stdout is a single line — the output path — so it is safe to capture:

```text
dist/ChatGPT-26.901.31953-x86_64.AppImage
```

Each AppImage embeds Gear Lever / AppImageSpec update information:

```text
gh-releases-zsync|h311x|chatgpt-appimage|latest|ChatGPT-*-x86_64.AppImage.zsync
```

After you drop a Release build into Gear Lever, updates should auto-detect from that metadata — no pasted URL. Releases also publish the companion `ChatGPT-<ver>-x86_64.AppImage.zsync` next to the AppImage.

If a build has no embedded info (older files, or a tool that ignores `.upd_info`), the GitHub Releases wildcard still works as a manual fallback:

```text
https://github.com/h311x/chatgpt-appimage/releases/download/*/ChatGPT-*-x86_64.AppImage
```

### Automatic releases

`.github/workflows/release-appimage.yml` builds that AppImage on `ubuntu-24.04` and publishes a GitHub Release (`v<deb-version>`, assets `ChatGPT-<ver>-x86_64.AppImage` and `ChatGPT-<ver>-x86_64.AppImage.zsync`). It does **not** commit binaries to git.

- **Schedule:** every 6 hours, the job reads the official APT `Packages` index. If `v<ver>` already has both the AppImage and `.zsync` assets, it exits without building (idempotent). A tag/release with missing assets is rebuilt and the assets are replaced.
- **Manual:** Actions → **Release AppImage** → **Run workflow** (the workflow file must already be on `main`). Same skip rule, unless you check **force** to rebuild and replace assets for the current official `.deb` version.
- **Packaging push:** a push to `main` that changes `scripts/build-appimage.sh`, `packaging/`, or this workflow rebuilds the current official version and replaces Release assets (so a packaging fix does not wait on the next OpenAI version bump).

Local `./scripts/build-appimage.sh` still works if you want an AppImage without waiting for CI.

### Options

| Flag / env | Meaning |
| --- | --- |
| `--deb PATH` / `CHATGPT_DEB` | Use a `.deb` you already downloaded |
| `--version VER` / `CHATGPT_VERSION` | Fetch `chatgpt_<VER>_amd64.deb` from the versioned pool |
| `--latest-url` | Fetch the mutable rolling URL `…/latest/chatgpt_amd64.deb` |
| `--output-dir DIR` / `OUTPUT_DIR` | Where to write the AppImage (default `dist/`) |
| `UPDATE_INFORMATION` | Override the embedded `gh-releases-zsync|…` string (default: this repo’s GitHub Releases) |

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
3. Install the official `.desktop` + PNG (plus `StartupWMClass=ChatGPT` for KDE) and `packaging/AppRun`.
4. Pack with [appimagetool](https://github.com/AppImage/appimagetool) as `ChatGPT-<deb-version>-x86_64.AppImage`, passing `-u` / `UPDATE_INFORMATION` so the ELF `.upd_info` section and a `.zsync` sidecar are produced.

There is **no linuxdeploy** pass. Shared libraries are not copied out of the build host. `AppRun` execs the official `ChatGPT` binary and does **not** set `LD_LIBRARY_PATH` (so host Mesa wins over any bundled SwiftShader/EGL lookup tricks).

## Runtime libraries (thin)

The official `.deb` Depends (GTK 3, NSS, ALSA, X11, …) plus Electron extras (`libXss`, `libXtst`, `libsecret`, …) must resolve on the **host**.

- **SteamOS 3.8+ / Steam Deck Desktop Mode:** those SONAMEs are present; this is the supported target.
- **Other distros:** install whatever the official package would (`libgtk-3-0`, `libnss3`, `libsecret-1-0`, `libxss1`, `libxtst6`, `libnotify4`, …). If `ldd` on `usr/lib/chatgpt/ChatGPT` reports `not found`, install that package — do not expect the AppImage to bundle it.
- **glibc:** not bundled. The official `.deb` already wants a current `libc6` (SteamOS 3.8 ships 2.41). Very old Deck images may be too old.
- **GPU:** Mesa / NVIDIA stay on the host. That is what you want on SteamOS.

## SteamOS / Gear Lever notes

- **Desktop Mode** is required for a GUI. Game Mode will not show this windowed Electron app usefully.
- Install [Gear Lever](https://flathub.org/apps/it.mijorus.gearlever), drop the AppImage on it, and integrate. Release builds embed `gh-releases-zsync` metadata, so Gear Lever should offer updates without a manual URL. Fallback if it does not: `https://github.com/h311x/chatgpt-appimage/releases/download/*/ChatGPT-*-x86_64.AppImage`.
- **FUSE:** type-2 AppImages mount via FUSE (`libfuse2`). SteamOS and some immutable images do not ship it. Gear Lever often extracts AppImages, which avoids FUSE. Otherwise:
  ```bash
  APPIMAGE_EXTRACT_AND_RUN=1 ./ChatGPT-*-x86_64.AppImage
  # or
  ./ChatGPT-*-x86_64.AppImage --appimage-extract-and-run
  ```
- **Sandbox:** the official package has no `chrome-sandbox`. Chromium uses user namespaces. If a host blocks those, start with `--no-sandbox` (last resort).
- **xdg-open / git:** not bundled. The host’s tools are used for browser links and Codex git features.

## GUI / smoke checks

The build script’s CLI smoke check is: the AppImage exists, is a 64-bit ELF, is executable, ELF `.upd_info` contains the expected `gh-releases-zsync` string, the `.zsync` sidecar exists with a `Length` that matches the AppImage and a 40-hex `SHA-1`, and `--appimage-help` / `--appimage-offset` work. `ChatGPT --version` is logged; a mismatch is a note, not a failure. It does **not** open the GUI (that would hang a headless build).

On a desktop, run the AppImage directly (needs **libfuse2** / `libfuse.so.2`). This packaging VM’s XFCE session (`DISPLAY=:1`) launched the thin AppImage with a native FUSE mount and showed the official **Sign in to ChatGPT** window — no extra Electron flags. SteamOS / Gear Lever is still the real target.

If FUSE is missing:

```bash
APPIMAGE_EXTRACT_AND_RUN=1 ./dist/ChatGPT-*-x86_64.AppImage
```

## Out of scope (v1)

- arm64
- Cloudflare / static URL redirects
- Fat / linuxdeploy bundling of Ubuntu GTK/NSS for older distros

## License

Packaging scripts in this repository are available under the terms you use for the rest of the project.

The AppImage contents include OpenAI’s proprietary ChatGPT desktop application and third-party components (Electron / Chromium). See `usr/share/doc/chatgpt/copyright` inside the `.deb` / AppDir for Electron’s MIT notice, and OpenAI’s product terms for the app itself.
