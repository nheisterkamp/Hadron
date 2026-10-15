# Hadron

Hadron runs Windows games from the macOS Steam client through Steam Play, with an
open-source Wine runtime that it builds itself.

Hadron is a fork of [NotProton](https://github.com/NotProtonNot/NotProton), and nearly
all of its Steam integration is NotProton's work. NotProton is built around a commercial
Wine distribution and deliberately supports only that, so please report problems with
Hadron here, not there.

It follows the Steam client versions NotProton supports, currently the stable client
(version 1791918634) and the beta (version 1791686101).

## How it works

- **Steam Play in macOS Steam.** A dylib injected into the Steam client enables the
  Steam Play support that macOS Steam carries but keeps switched off, and registers
  Hadron as a compatibility tool.
- **The Wine runtimes.** Hadron downloads them from this repository's releases, or
  `runtime/build-wine.sh` builds them, with lsteamclient, the steam.exe shim, wine-mono
  and wine-gecko built in. Each is a small definition in `runtime/runtimes`, and each
  shows up in Steam as its own compatibility tool:
  - **Wine 11.15**, the default.
  - **Wine Staging 11.15**, with the wine-staging patch set.
  - **Wine 11.19**, the newest development release.
  - **CrossOver Wine 26.3**, built from CodeWeavers' published source, the one runtime
    that runs D3DMetal.
  - **Wine 11.19 for Apple Silicon**, native arm64 Wine that runs x86 games with
    [FEX](https://github.com/FEX-Emu/FEX) instead of Rosetta. It needs macOS 26.5.

  A game's prefix moves between the Rosetta and Apple Silicon runtimes in place. The
  patches in `runtime/patches` redirect Steam's steamclient to lsteamclient in Wine's
  loader, name the prefix profile `steamuser` like Proton does, let a DLL overlay stand
  in for Wine's own Direct3D, and hand games Steam Input's virtual controller in the
  layout XInput expects. `runtime/patches/wine-11.19-fex` ports arm64 Wine to macOS, and
  `runtime/fex` ports FEX's unix side.
- **Graphics.** Direct3D 10 and 11 go to Metal through
  [DXMT](https://github.com/3Shain/dxmt) by default. Each game's Properties in Steam has a
  Hadron panel to pick DXVK 3.1 on KosmicKrisp, DXVK 1.10 on MoltenVK, D3DMetal (with
  CrossOver Wine, once added from Apple's Game Porting Toolkit or CrossOver), or Wine's
  own Direct3D. On Apple Silicon Wine, DXVK 1.10 and Wine's own Direct3D are available.
- **Starting games.** A small window follows each launch: its steps, the game's Windows
  processes and logs, and a warning when nothing happens. It can stop the game and save
  diagnostics.

## Status

Early, but games run. All runtimes boot, reach Steam through lsteamclient for 32 and 64
bit games, make HTTPS connections through schannel, and create Direct3D 11 devices with
every backend they ship. Hadron updates itself through Sparkle. Not yet done:

- Direct3D 12 outside D3DMetal goes no further than Wine's own vkd3d manages on MoltenVK.
- The Apple Silicon runtime is new and starts heavy programs slowly: Ubisoft Connect takes
  about a minute, against seconds under Rosetta. It is there for when Apple drops
  Rosetta, in macOS 28.

**Valve Anti-Cheat is not supported.** VAC titles launch in Insecure Mode and cannot
matchmake.

## Building

```
brew install mingw-w64 bison flex autoconf cmake ninja
make runtime                  # every runtime in runtime/runtimes
make bridge dobby fonts app
```

`make fonts` also needs FontForge, GNU patch and afdko 4.0. Then open `out/Hadron.app`,
add a folder from `out/runtime` with "Add Wine Runtime…" (or put it in
`~/Library/Application Support/hadron/runtimes/`), set it up, and install into Steam.

Hadron can also download the runtimes. `runtime/release.sh <tag> <runtime>...` packs
staged runtimes into `out/release/<tag>` and writes the manifest the app bundles, with
each archive's SHA-256; `--publish` uploads them as a GitHub release. The archives leave
out D3DMetal, which Apple's licence does not allow passing on: Hadron's "Add D3DMetal…"
takes it from the Game Porting Toolkit or CrossOver on the user's Mac. An Apple Silicon
runtime is only packed when its loader is signed with a Developer ID profile, since a
development profile runs on its own devices only.

`app/release.sh` releases Hadron itself: it signs the app and all code in it with
Developer ID and the hardened runtime, has it notarized, signs the zip for Sparkle and
adds it to the appcast on the `updates` branch, which Hadron's update checks read.
`--publish` uploads it as GitHub release `app-<version>`. For every release, raise
`HADRON_VERSION` in `dylib/version.h` and write what changed in `CHANGELOG.md`, which
becomes the release notes and the text in Sparkle's update window.

## Source layout

The macOS app is in `app`, and the code injected into Steam is in `dylib`.
`dylib/feats/compat_run.sh` is the compatibility tool's launch script. `lsteamclient` is
a macOS port of Valve's lsteamclient, and `steam-shim` a port of the steam-helper from
Proton 9.0. `runtime` builds the Wine runtime, with its patches and tests.

Please read NOTICE for license information.

## Made with AI

Much of what Hadron adds to NotProton was written by Claude, Anthropic's AI model,
working in Claude Code: the Wine runtime builds and their patches, the macOS port of FEX
for Apple Silicon, and most of the app's newer features, such as runtime downloads, the
launch window and the update channel. Niels Heisterkamp directed that work, reviewed it
and tested it. NotProton's code, which Hadron builds on, is its author's own.

The code has tests, and every runtime is checked before it is released, but it has run on
few machines and games so far. Please report what breaks as an issue.

## Thanks

NotProton's author, for the project this is built on. And, as NotProton's README puts it,
the people who worked on similar ideas before:

[Nat Brown](https://github.com/natbro) made [Kaon](https://github.com/natbro/kaon), which
is similar in goals.

mont127's [Neutron](https://github.com/mont127/Neutron) is also a similar idea, implemented
differently.

[Gio](https://github.com/giodotblue) was working on enabling Steam Play inside of Steam on
macOS before NotProton was released.
