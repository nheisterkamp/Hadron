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
- **The Wine runtimes.** `runtime/build-wine.sh` builds x86_64 Wine runtimes that run
  under Rosetta, with lsteamclient, the steam.exe shim, wine-mono and wine-gecko built
  in. Each runtime is a small definition in `runtime/runtimes`, and each shows up in
  Steam as its own compatibility tool:
  - **Wine 11.15**, the default.
  - **Wine Staging 11.15**, with the wine-staging patch set.
  - **Wine 11.19**, the newest development release.

  Three small patches in `runtime/patches` redirect Steam's steamclient to
  lsteamclient in Wine's loader, name the prefix profile `steamuser` like Proton does,
  and let a DLL overlay stand in for Wine's own Direct3D.
- **Graphics.** Direct3D 10/11 goes to Metal through [DXMT](https://github.com/3Shain/dxmt).
  Vulkan comes from MoltenVK. Each game's Properties in Steam has a Hadron panel to
  switch it to Wine's own Direct3D instead.

## Status

Early. The runtime boots, the steamclient redirect works for 32 and 64 bit games, and
DXMT creates Direct3D 11 devices. Not yet done:

- an arm64 runtime. The runtimes need Rosetta, which Apple drops in macOS 28. Running
  Wine natively needs Wine patches that are not upstream yet, a macOS port of FEX for
  the x86 games, which is not public, and Apple entitlements tied to a developer account.
- Direct3D 12 beyond what Wine's own vkd3d manages on MoltenVK.
- TLS (schannel) inside Wine, which needs an x86_64 GnuTLS.
- automatic updates. They are switched off until Hadron publishes signed releases.

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
`--publish` uploads it as GitHub release `app-<version>`; raise `HADRON_VERSION` in
`dylib/version.h` for every release.

## Source layout

The macOS app is in `app`, and the code injected into Steam is in `dylib`.
`dylib/feats/compat_run.sh` is the compatibility tool's launch script. `lsteamclient` is
a macOS port of Valve's lsteamclient, and `steam-shim` a port of the steam-helper from
Proton 9.0. `runtime` builds the Wine runtime, with its patches and tests.

Please read NOTICE for license information.

## Thanks

NotProton's author, for the project this is built on. And, as NotProton's README puts it,
the people who worked on similar ideas before:

[Nat Brown](https://github.com/natbro) made [Kaon](https://github.com/natbro/kaon), which
is similar in goals.

mont127's [Neutron](https://github.com/mont127/Neutron) is also a similar idea, implemented
differently.

[Gio](https://github.com/giodotblue) was working on enabling Steam Play inside of Steam on
macOS before NotProton was released.
