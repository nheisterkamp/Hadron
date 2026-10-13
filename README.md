# Hadron

Hadron runs Windows games from the macOS Steam client through Steam Play, with an
open-source Wine runtime that it builds itself. It does not need CrossOver.

Hadron is a fork of [NotProton](https://github.com/NotProtonNot/NotProton), which does
the same with CrossOver. Nearly all of the Steam integration is NotProton's work. NotProton
deliberately supports only CrossOver, so please report problems with Hadron here, not
there.

## What is different from NotProton

- **The runtime.** `runtime/build-wine.sh` builds an x86_64 Wine 11.15 that runs under
  Rosetta, with lsteamclient, the steam.exe shim, wine-mono and wine-gecko built in.
  NotProton patches a copy of CrossOver's binaries instead. Hadron makes the same changes
  in Wine's source (`runtime/patches`), so there are no per-build hashes to pin.
- **Graphics.** Direct3D 10/11 goes to Metal through [DXMT](https://github.com/3Shain/dxmt).
  Vulkan comes from MoltenVK. To use Wine's own Direct3D for one game instead, put
  `NOTPROTON_GRAPHICS=wined3d %command%` in that game's launch options.
- **No license check.** The runtime is free software. CrossOver copies are still supported
  and still need a valid CrossOver license.

## Status

Early. The runtime boots, the steamclient redirect works for 32 and 64 bit games, and DXMT
creates Direct3D 11 devices. Not yet done:

- an arm64 (FEX) runtime. The runtime is Rosetta only.
- D3DMetal, Apple's Direct3D 12 translation layer. It cannot be redistributed.
- TLS (schannel) inside Wine, which needs an x86_64 GnuTLS.
- automatic updates. They are switched off until Hadron publishes signed releases.

## Building the runtime

```
brew install mingw-w64 bison flex autoconf cmake ninja
bridge/setup-wine-tree.sh
runtime/build-wine.sh
```

Add the result, `out/runtime/wine-11.15`, with "Add CrossOver or Wine…", or put it in
`~/Library/Application Support/notproton/runtimes/`.

## NotProton's notes

The rest of this file is NotProton's README. It still applies to CrossOver copies.

### NotProton

NotProton enables the Steam Play experience from Linux Steam in the macOS Steam client.

This is done by forcibly enabling the Steam Play functionality in macOS Steam (which is
present and inert) as well as by porting some components of Valve's Proton to macOS.

This tool is intended to be used with the stable Steam Client (version 1788652215) as well as the beta Steam Client (version 1791686101) paired with **CrossOver 26.3 or CrossOver [Preview](https://www.codeweavers.com/preview)
20261006 or 20260821**, with more supported versions to come.

Supporting specifically CrossOver is a design goal of this project. Better support for modifying CrossOver (using custom builds of DXMT/patched D3DMetal/MacGameVideoFix) will come in a future update, but support for alternatives to CrossOver itself is not planned.

Both the FEX and the Rosetta versions are supported. I recommend using the FEX version of the 
Preview 20261006, as it includes both the FEX version as well as the Rosetta one. 

I further recommend going into Steam Settings - Compatibility and selecting the Rosetta version as your default compatibility tool. You can select FEX on a per game basis by right clicking a game in Steam, going into Properties - Compatibility and selecting FEX there.

If a game has a native macOS version as well as a Windows one, Steam will download the macOS version. To override this behavior, right click on the game, select Properties, select Compatibility. Enable 'Force the use of a specific Steam Play compatibility tool'. Select whichever version of CrossOver you want to do use. That will make Steam download the Windows version. Unchecking the 'Force the use...' box or selecting 'No Compatibility Tool' in the drop down list will revert to the macOS version of the game, with the specifics there varying based on your Steam version.

**Valve Anti-Cheat is not supported.** Proton itself does not support VAC in Valve titles; Valve ships native Linux ports instead. VAC titles will launch in Insecure Mode and will not allow matchmaking. 

**This project now has a brew cask.** For brew users, you can install via ``brew install --cask notprotonnot/notproton/notproton``

Please read NOTICE for license information.

Please open issue reports with any issues. PRs are welcome and encouraged.

There are many people who worked on similar ideas, similar projects. I did not base NotProton on their work, but I still want to 
give thanks to the people who came before me:

[Nat Brown](https://github.com/natbro) made [Kaon](https://github.com/natbro/kaon), which is similar in goals to NotProton.

mont127's [Neutron](https://github.com/mont127/Neutron) is also a similar idea, but implemented differently. 

[Gio](https://github.com/giodotblue) was working enabling Steam Play inside of Steam on macOS prior to the release of NotProton itself. 
I would have done things differently had I been aware of that. 

Thanks to everyone who has positively contributed to macOS gaming. 

Developer Notes:

As far as the source structure goes, the macOS app itself is located in the ```app``` folder. The core logic is in ```dylib```.
```lsteamclient``` is a macOS port of Valve's lsteamclient. ```steam-shim```is a port of Valve's
steam-helper from Proton 9.0. ntdll-patch patches the copy of CrossOver that the app
makes/places in the ```~/Library/Application Support/notproton/runners/``` folder so that
lsteamclient is loaded.

Hadron adds `runtime`: the Wine runtime build, its patches and its tests.
