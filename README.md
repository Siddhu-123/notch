# Notch

Notch is a native macOS menu-bar utility inspired by [Boring Notch](https://github.com/TheBoredTeam/boring.notch). It turns the top-center notch area into a quiet, animated control surface.

## Included

- Hover-to-expand live activity panel with smooth spring transitions
- Apple Music and Spotify now-playing metadata, artwork, transport controls, seeking, and volume
- Calendar events and Reminders with native permission prompts
- Persistent file Shelf with drag and drop, multi-select, Finder reveal, open, remove, and AirDrop
- Private Mirror module with an on-demand camera preview and native privacy controls
- Native volume, mute, display brightness, battery, charging, and compact HUD controls
- Menu-bar controls, launch-at-login, pin-open mode, visibility, theme, module preferences, interaction modes, and panel sizing
- Eight-band audio-reactive visualizer that measures system output in dB through Core Audio and never requests screen-recording or microphone access
- Shelf sections for files, local clipboard history, pinned snippets, and bookmarked folders
- Workspace views for a persistent focus timer, battery/audio dashboard with battery refresh, voice controls, Call tools, and live assistant activity
- Quick-action pills, shared motion, camera-safe navigation, and optional pixel cat, festive lights, and file-drop paw

Home pairs music with calendar or your chosen accessory. When no track is active, Open Music launches Music; playback controls appear once a track is available. Shelf keeps Files, Clipboard, and Folders together. The grid button opens Workspace. Companions and effects are configurable in Settings and respect macOS Reduce Motion.

Clipboard monitoring starts off, remembers your choice across restarts, and keeps text only on this Mac. It skips concealed and transient clipboard items and retains pinned snippets when history is cleared. The folder browser lists only immediate contents of folders you choose and restores your selected bookmarked folder after restart.

Voice starts only when you press Start and requires on-device recognition for your language. Approved permissions are reused; an unanswered startup stops after one minute and allows retry. Press Finish after speaking; commands run strictly from final recognition matching known commands. Leaving the view, hiding, or closing the notch cancels recording. A new recording clears the prior transcript once capture begins. Media commands report when no track is active. Transcripts stay in memory unless you explicitly copy or save them. Examples: “play music”, “open shelf”, and “start focus for 25 minutes”.

Focus keeps presets available while idle and displays the actual session duration while running or paused.

Dashboard shows battery, audio, and agent status with a manual battery refresh. Accessory levels appear only when macOS exposes them. Call tools lists installed FaceTime, Teams, and Zoom apps, opens the selected app, and offers system microphone mute when supported. App availability and microphone state refresh while this view is open. Answering, ending, and muting individual calls stay in the call app; output mute stays in Controls. Assistant shows connected agents’ real states and step counts.

## Run

Open `notch.xcodeproj` in Xcode 16 or later and run the `notch` scheme on macOS 15.5 or later. The app runs as an accessory with a menu-bar item and a borderless panel at the top of the active display.

The first use of Music or Spotify controls may ask for Automation permission. Calendar and Reminders access is requested only when those modules are opened or enabled. The visualizer reads system output through a private Core Audio process tap; it does not request screen-recording or microphone access.


## Sketch layout and local tools

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
