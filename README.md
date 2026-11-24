# Edgeflow

用 Mac 的鍵盤和觸控板控制同一個網路上的 Linux / Windows 電腦，游標推過螢幕邊緣就切過去。
Control a Linux or Windows computer on the same network with your Mac's keyboard and trackpad — push the cursor past the screen edge to cross over.

Built on [Deskflow](https://github.com/deskflow/deskflow); Edgeflow adds the parts around it:

- **一鍵配對 / One-line pairing** — the Mac shows a command to paste on the other computer (or installs it over SSH with an IP and password). It installs Deskflow, sets up TLS certificates both ways, and connects, with no trust prompts.
- **邊緣阻力 / Edge resistance** — hold the cursor against the edge for a moment (adjustable) before it crosses, with a charge sound.
- **特效與音效 / Effects and sounds** — glow and ripple where the cursor arrives, on both computers; themes, color, volume.
- **Mac 按鍵習慣 / Mac key habits** — ⌘ acts as Ctrl, Caps Lock switches 中/英, ⌘⇧3/4/5 take screenshots on the other computer.
- **剪貼簿 / Clipboard** — text and images both ways; Mac screenshots go straight to the clipboard.
- **只在區網 / LAN only** — the computers talk directly over the local network, encrypted.

## Requirements

- Mac: macOS 14+, Apple silicon
- Other computer: Linux (GNOME on X11 works best; Flatpak is used for Deskflow) or Windows 10/11
- Both on the same network

## Build

```sh
./build.sh
```

Needs Xcode command-line tools and [Deskflow.app](https://github.com/deskflow/deskflow/releases) in `/Applications` (or set `DESKFLOW_APP`), which gets bundled into `Edgeflow.app`. The result is installed to `/Applications/Edgeflow.app`.

The app is unsigned. To keep macOS's Accessibility permission across rebuilds, create a code-signing certificate named **Edgeflow Local Signing** in Keychain Access; `build.sh` uses it when present.

## Layout

| Path | What |
| --- | --- |
| `app/Sources/` | The Mac app (SwiftUI): settings, pairing server, Deskflow server control, discovery, SSH install |
| `app/Resources/payload/` | What the Mac serves to the other computer: installers and helpers for Linux and Windows |
| `mac_edge_fx.swift` | The Mac-side arrival effect |
| `app/make_icon.swift` | Draws the app icon |

## License

MIT — see [LICENSE](LICENSE). Builds bundle Deskflow, which is GPL-2.0.
