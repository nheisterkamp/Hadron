# Changelog

Each release of the Hadron app. `app/release.sh` takes a version's section from here for
the GitHub release and for the update window Sparkle shows.

## 1.0.3

- Closing a Ubisoft game such as Trackmania now closes Ubisoft Connect too, about 15
  seconds later, so Steam sees the game has stopped. Before, Ubisoft Connect kept running
  and Steam showed the game as still running.
- Steam's library filter can show only Windows games, and the Mac filter no longer lists
  Windows games.
- Windows programs added to Steam as non-Steam games run with Hadron's default
  compatibility tool, and their prefixes are named after the shortcut.
- Steam no longer takes the focus away from a game while it starts.
- High Resolution also doubles Windows' text and interface scaling, so games are not
  drawn at half size, and turning it off halves it again.
- The Mac keeps its display awake while a game runs.
- Games that install Microsoft's Visual C++ runtime use it instead of Wine's copy, which
  fixes Unreal games that said the runtime was missing.
- Hadron and its Steam settings are available in Italian.
- Works with the Steam beta client of October 2026 (1792192922).
- Fixes from NotProton for Steam installed on another drive, Valve downloads that
  stalled, and changes to a prefix while a game used it.

## 1.0.2

- Runtime downloads show a progress bar with megabytes and a percentage, and can be
  stopped. Before, the download said 0% until it had finished.
- Wine 11.19 for Apple Silicon can be downloaded. It runs x86 games with FEX instead of
  Rosetta and needs macOS 26.5.
- The Update and Repair rows say which Hadron is installed for Steam and which this app
  brings.
- A new build of Hadron no longer shows as an update when only the signatures of its
  helper programs changed.
- A supported runtime that is not on this Mac and cannot be downloaded yet keeps a row
  that says so, instead of vanishing from the list.

## 1.0.1

The first release with automatic updates.

- **Updates:** Hadron is signed with Developer ID, notarized by Apple, and updates itself
  through Sparkle. Hadron → Check for Updates… works.
- **Runtime downloads:** Wine 11.15, Wine Staging 11.15, Wine 11.19 and CrossOver Wine
  26.3 can be downloaded from the Status page, checked and set up in one step. CrossOver's
  download comes without D3DMetal; Add D3DMetal… takes it from Apple's Game Porting
  Toolkit or CrossOver on your Mac.
- **Launch window:** while a game starts, a small window shows each step, the game's
  Windows processes, both logs, and a warning when nothing happens for 30 seconds, with
  Stop Game and Save Diagnostics. The Launches section keeps recent launches.
- **Controllers:** Steam Input's virtual pad reaches games, with its buttons in the right
  order. Before, games under every runtime saw no controller.
- **Steam's permissions:** Steam keeps its input and device permissions across Hadron
  updates, because Hadron signs it with a stable identity of its own instead of ad hoc.
- **Switching runtimes:** a game's prefix moves between the Rosetta and Apple Silicon
  runtimes in place, instead of asking for a rebuild. Moving back to CrossOver works too.
- **Apple Silicon:** Ubisoft Connect, and with it Trackmania, starts under FEX.
- Open Steam in the toolbar and the Setup menu, a new icon, and the Status page follows
  Steam quitting and starting.
