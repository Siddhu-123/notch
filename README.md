# Notch

A native macOS menu-bar utility that turns the top-centre notch area into an animated control surface: music, calendar, a file shelf, system controls, a camera mirror and a growing set of local tools. Built with SwiftUI. Inspired by [Boring Notch](https://github.com/TheBoredTeam/boring.notch).

> Status: working prototype under active development. See [Known issues](#known-issues).

## Features

- **Live activity panel**: hover to expand, spring transitions, pin-open mode, follows the display you are using.
- **Music**: Apple Music and Spotify metadata, artwork, transport, seeking and volume; up-next, lyrics and media-key guard.
- **Calendar and Reminders**: native permission prompts, requested only when you open the module.
- **Shelf**: persistent file shelf with drag and drop, AirDrop, Finder reveal, text-only clipboard history (off by default), pinned snippets and bookmarked folders.
- **Mirror**: on-demand camera preview with native privacy controls.
- **System controls**: volume, mute, display brightness, battery, a per-app sound mixer with routing and a headphone guard.
- **Audio visualiser**: eight-band spectrum from system output via a Core Audio process tap; no screen-recording or microphone access.
- **Workspace**: focus timer, dashboard, voice commands (on-device recognition only), call tools and a live assistant-activity view for coding agents (see `AgentBridge/`).
- **Tools**: window switcher and snapping, quit protection, pointer tweaks, Caps Lock Hyper key, command bar with safe math, radial menu, cleaning mode, capture and watch region, media conversion, and a maintenance suite (cleanup, leftovers, duplicates, login items).
- **Utilities**: scratchpad, clean URL, keep awake and a system monitor. Twelve interface languages.

## Requirements

- macOS 15.5 or later
- Xcode 16 or later

## Build and run

```bash
git clone https://github.com/Siddhu-123/notch.git
cd notch
open notch.xcodeproj
```

Run the `notch` scheme. From the command line:

```bash
xcodebuild -project notch.xcodeproj -scheme notch -configuration Debug build
```

If you have several Xcode versions installed, point `DEVELOPER_DIR` at the one you want, for example `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`. The project's signing team belongs to the author; change it under Signing & Capabilities, or build with `CODE_SIGNING_ALLOWED=NO`.

`create_dmg.sh` packages a Release build into a `.dmg`.

The app runs as an accessory with a menu-bar item and a borderless panel at the top of the active display. The first use of Music or Spotify controls may ask for Automation permission. Some tools use the bundled `NotchSystemHelper` XPC service.

## Privacy

Clipboard monitoring is off until you enable it, keeps text only on this Mac and skips concealed and transient items. Voice recognition is on-device and starts only when you press Start; transcripts stay in memory unless you copy or save them. The bundled utilities need no network access.

## Known issues

- Layout recursion warnings (`layoutSubtreeIfNeeded`) and occasional negative view-size warnings are still reproducible in Release builds.
- Moving the panel between two physical displays has not been fully confirmed.
- Fullscreen detection is a conservative window-based heuristic, not a direct Spaces query.
- A file-URL sandbox extension error (`-20`) appears in some drag-and-drop logs; the exact trigger is unknown.
- Several upstream features are not implemented (see the feature list above for what is).

## Repository layout

| Path | Contents |
| :--- | :--- |
| `notch/` | App source (SwiftUI); `Wave7/` holds the feature modules |
| `NotchSystemHelper/` | XPC helper for privileged and background features |
| `AgentBridge/` | Scripts that report coding-agent activity to the panel |
| `Vendor/` | MediaRemoteAdapter framework and third-party licences |
| `notchTests/`, `notchUITests/` | Unit and UI tests |

## Licence

GPL-3.0-or-later. See [LICENSE](LICENSE). Parts of the utilities are adapted from Vorssaint (GPL-3.0-or-later) and the music bridge uses MediaRemoteAdapter (BSD-3-Clause); full notices are in [Vendor/THIRD_PARTY_LICENSES.md](Vendor/THIRD_PARTY_LICENSES.md).

---

## Design notes: sketch layout and local tools

The expanded Island follows the hand sketch: one continuous frame, three joined
rectangular tiles on each side, nine along the base, diagonal corner joints,
and a rounded central recess with a camera outline. Keys sink on press and
spring back on release. Disabled tools leave blank tiles to preserve the frame.
Right-click the frame for Settings, Keep open, and Collapse; double-click the
inner bottom lip to close. The center keeps Home, Shelf, Apps, Controls, Mirror
and Workspace. The collapsed and minimal activities remain.

The lower rail also opens four local utilities adapted from Vorssaint:

- Scratchpad: autosaved notes and explicit copying.
- Clean URL: manually strip tracking while preserving signed links and raw query encoding.
- Keep Awake: 30-minute or one-hour idle-sleep sessions, with Stop. This does not override lid-close sleep.
- System Monitor: real CPU load, estimated RAM and a 30-reading CPU graph; sampling stops when the page closes.

General Settings has a Utilities switch. Turning it off removes the new tools
and stops their active services while preserving the saved note. No new
permissions or network requests are needed by these utilities.

Source portions: https://github.com/vorssaint/vorssaint-utils at
3c10e1bd30101499135fa5d7591f2d3c5af4cd17, GPL-3.0-or-later. Full notices and
license are bundled in Vendor/THIRD_PARTY_LICENSES.md.
