# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

ReDeFin is an unofficial Jellyfin client for the **Freebox Player** (Révolution / Delta), written in QML (QtQuick 2.15) and QML-flavoured JavaScript. Upstream is <https://github.com/laborantine/ReDeFin> (GPL-3.0), which publishes its sources only as `.fbxqml` release assets, not in its git tree. This repository is an extraction of those assets plus local fixes and tooling. Human-facing documentation is in `CONTRIBUTING.md`, `tests/README.md` and `tools/README.md`; read them before changing the tooling.

## Platform facts that shape everything

- **No compilation.** A `.fbxqml` package is a plain `tar.gz` of the files whitelisted in `ReDeFin.fbxproject`. The Player interprets QML/JS at runtime. "It compiles" here means `./check.sh` passes.
- **The Player runs Qt 5.15** with firmware-provided `fbx.*` modules. The app imports `fbx.application` (the `Application` root, `Settings` persistence), `fbx.ui.base` (`Clickable`…) and `fbx.system` (the `Device` singleton, used to tell Révolution from Delta/Devialet).
- **Local tooling runs Qt 6** through a PySide6 venv. It validates syntax, pure logic and QML wiring only. `QtMultimedia` is not available locally, so `qml/pages/playeroverlay.qml` cannot be instantiated in tests. Rendering, media playback and real `fbx.system` behaviour can only be checked on a Player.
- The Freebox Révolution is a very low-power device (Intel CE4100). Much of the code exists to limit JSON size, delegate churn and shader cost. Treat performance-motivated oddities as intentional until proven otherwise.

### Freebox SDK references

- SDK index: <https://dev.freebox.fr/sdk/>
- Player QML SDK (developer mode, packaging, FreeStore/FreeFactory): <https://dev.freebox.fr/sdk/player.html>
- Freebox OS API (the Server/gateway HTTP API, not used by the app itself): <https://dev.freebox.fr/sdk/os/>
- `libfbxqml`, the official QML library providing `fbx.*` for desktop tooling (2014, pure QML/JS, **lacks `fbx.system`**): <https://github.com/fbx/libfbxqml>, docs at <https://dev.freebox.fr/sdk/libfbxqml/>
- Free's Qt Creator plugin (obsolete as a binary, targets Qt Creator 4.3, but its source is the only specification of the package format, manifest validation and remote-launch protocol): <https://github.com/fbx/freebox-qtcreator-plugin>
- Original Python 2 remote launcher that `tools/fbx-run.py` ports: <https://github.com/fbx/freebox-dev-utils>

## Commands

One-time setup (no root, no system Qt; creates `~/.cache/redefin-qttools/venv` with PySide6-Essentials and clones libfbxqml into `~/.cache/redefin-qttools/libfbxqml`; override with `REDEFIN_QT_VENV` / `REDEFIN_LIBFBXQML`):

```bash
./tools/setup-qt-tools.sh
```

Full verification, required before every commit (QML syntax lint, JS syntax check, Node tests, Qt Quick tests, Python tests; `--no-lint` / `--no-tests` to skip parts):

```bash
./check.sh
```

Single test layers / single tests:

```bash
node --test tests/js/pressgesture.test.js
~/.cache/redefin-qttools/venv/bin/python3 tests/qml/run_qml_tests.py            # all tst_*.qml, headless
~/.cache/redefin-qttools/venv/bin/python3 tests/qml/run_qml_tests.py -input tests/qml/tst_profiletile.qml
python3 -m unittest discover -s tests/py -v
```

`node --test tests/js/` (a directory) fails on Node 24; always pass files. `qmllint` only fails the build on `[syntax]`; the thousands of `[unqualified]`/`[missing-property]` warnings from linting Qt 5 code with Qt 6 are expected.

Build a package (`build/ReDeFin_<manifest version>.fbxqml`; `-o` for another path; `-v <ref.fbxqml>` compares file list and per-file SHA-256 with a reference package):

```bash
./build.sh
```

Run the working tree on a real Player with live console output (no packaging needed):

```bash
python3 tools/fbx-run.py -t <player-ip> -v 2>&1 | tee build/run.log
```

## Running on the Player (developer mode)

- Enable it on the Player: **Réglages > Système > Mode développeur**. The Player then advertises `_fbx-devel._tcp.local.` over mDNS and accepts JSON-RPC on `http://<player>/pub/devel`.
- `tools/fbx-run.py` serves the repository over HTTP (default port 8234, refusing `.git/`, `build/`, `tests/`, `tools/`), calls `debug_qml_app` with the manifest URL, then relays the Player's stdout/stderr sockets as `[out]` / `[err]` lines. The Player fetches each QML/JS file on demand, so edits are picked up on the next launch.
- The Player must be able to reach this machine. Under WSL2 this requires mirrored networking **and** a Hyper-V firewall rule for the port (command in `CONTRIBUTING.md` / `tools/README.md`). The Player error `Failed to load application manifest from network: Timeout, check your firewall` means exactly this.
- Ignore in the console: `GET 404 .../qmldir` probes and `Application instance does not declare a handleUrl() function`.
- The Player logs full request URLs. Stream URLs carry `ApiKey=`. Mask tokens before quoting logs anywhere: `sed -E 's/(api_key|ApiKey|Token)=[^& ]*/\1=***/gi'`.

### Debugging on device

`qml/js/SafeLog.js` is deliberately neutralised in the public build and `qml/**` must not call `console.log` directly. Traces go through `qml/js/DevLog.js`: `DevLog.log(tag, message)` is a no-op because `ENABLED` is `false` in the repository and in every package. `tools/fbx-run.py` serves that single file with the flag flipped to `true` on the fly (never on disk), so traces exist only in a developer-mode run and show up as `qml: DevLog: [RDF] <tag> <message>` (the tag, not the file name, identifies the origin); `--no-dev-log` reproduces the public behaviour. `build.sh` and a Node test both refuse an enabled flag, and the exact line `var ENABLED = false;` must not be reformatted. The player is already instrumented (tags T1–T16: track pick, negotiation result, hard source reset phases, MediaPlayer errors and state changes, loading gate arm/release with reason, deferred reload, transport lock, focus restore). When adding traces: wrap URLs in `DevLog.maskUrl()`, keep every identifier in scope (an exception inside the playback paths breaks playback), and guard hot paths with `if (DevLog.ENABLED)`.

Qt 5.15 `MediaPlayer` codes seen in traces: `status` 1 NoMedia, 2 Loading, 3 Loaded, 4 Stalled, 5 Buffering, 6 Buffered, 7 EndOfMedia, 8 InvalidMedia; `playbackState` 0 Stopped, 1 Playing, 2 Paused.

## Architecture

### Shell and navigation

`main.qml` is the `fbx.application.Application` root. It owns the persisted `Settings` (sanitised: tokens are never persisted there) and loads `qml/pages/ShellPage.qml`. **ShellPage is the router**: `currentPage` is a string such as `"HomePage.qml?ctx=1"` loaded by an asynchronous `Loader`; pages ask for navigation through signals/functions (`requestNavigation`, `requestHomeLoading`) rather than loading each other. ShellPage also owns the global loading curtain (`CircleDotsLoader`), the page-transition curtain, overlays (`OverlayHub`, `ServerOverlay`) and the player lifecycle (`playerActive`, a separate loader for `playeroverlay.qml`). Context passed between pages travels in a shared object (`shared.__redefin…` keys) rather than in URLs. Page basenames are compared lower-case in ShellPage (`"detailmoviepage.qml"`), which is why such strings look like missing files.

Boot flow: `SplashPage` → stored profile picker (`LoginPage`, the "Qui regarde ?" screen) → token validated only when a profile is chosen → `HomePage`, which holds the loader until several gated fetches complete.

### JavaScript layers (`qml/js`, all `.pragma library`)

- `jellyfinBridge.js`: every Jellyfin HTTP call. Request objects with cancel/timeout, in-flight de-duplication, failure cooldowns, bounded JSON parsing. Imports `MediaCatalog.js` (item/library shaping), `SafeLog.js` (error-code normalisation such as `invalid_token`, `http_401`, `timeout`, `cancelled`; LAN host trust; no logging) and `clientId.js` (device id, `APP_VERSION`).
- `UserStore.js`: profiles, remembered sessions and token storage policy.
- Playback negotiation is a policy stack: `JellyfinPlaybackRouter.js` (chosen by `Device.model`) → `JellyfinPlaybackRevolution.js` or `JellyfinPlaybackDevialet.js` (hardware policy: device profile, containers, codec limits, subtitle methods) → `JellyfinPlaybackCore.js` (PlaybackInfo request, the long decision chain choosing DirectPlay / remux / transcode, audio and forced-subtitle auto-selection) → `JellyfinPlaybackCoreUrl.js` (URL building and query rewriting). Modules are imported with namespaces, never `Qt.include`, because the policies expose same-named functions.
- `playerOverlayHelper.js` (imported as `H`) holds the imperative logic of `playeroverlay.qml`: key handling, track switching, server-timed streams (`baseOffsetMs`, `StartTimeTicks`), the "hard source reset" state machine used when a stream must be reopened (`beginHardSourceReset` / `tickSourceReset` / `completeFresh…`), seek restore, and the video loading gate (`videoLoadingGate`, armed and released with a reason string). `playeroverlay.qml` mostly exposes thin façades (`function _x(){ H.x(root, mp, …) }`).
- Pure, unit-tested decision modules added locally: `PressGesture.js` (OK-key press/long-press state machine and removal confirmation, shared by `LoginPage.qml` and `ServerOverlay.qml`) and `DeferredReload.js` (reducer deciding whether a settings choice is applied now, deferred until resume when paused, cancelled or a no-op).

### Player behaviour rules worth knowing

- A track/quality change that requires reopening the stream restarts a server transcode (~2.5 s on Révolution). While **paused**, such choices are deferred and applied in a single negotiation when playback resumes; instantaneous changes (local text subtitles in pure DirectPlay) stay immediate.
- Every path that releases the loading gate historically required the `Playing` state; any new flow that can end paused must release it explicitly or the loader stays forever.
- The client never calls `DELETE /Videos/ActiveEncodings`; superseded transcodes die by the server's kill timer.
- Transport keys are ignored while a reload is in progress so blind key presses cannot trigger network seeks.

## Conventions

- Application code under `qml/` is **ES5** (no `let`/`const`/arrow functions/template strings/classes), uses no `QtQuick.Controls`, has French comments, and no direct `console.log` (use `DevLog`). Tests and tooling may use modern JS/Python.
- Put decision logic in a `.pragma library` module with no global mutable state and test it with Node via `tests/js/qmljs.js` (`loadQmlJs(path, {stubs})` evaluates a QML JS module, resolving `.import`, and returns its top-level symbols; objects it returns come from another realm, so compare fields rather than using `deepStrictEqual`). Test QML wiring with Qt Quick Test by instantiating the real page where possible (`tests/qml/tst_profiletile.qml` loads the actual `LoginPage.qml` with an empty `serverUrl` so no network is touched). `tests/qml/stubs/` provides `fbx.system` and `QtGraphicalEffects`; extend the stubs when a page needs more.
- New files in `qml/js`, `qml/pages`, `qml/components`, `qml/images` are packaged automatically. A new **directory** must be added to both `ReDeFin.fbxproject` and the mirrored list in `build.sh`.
- One logical change per commit, each passing `./check.sh`, each with its test, so every fix can be offered upstream on its own (as `git format-patch` patches attached to an issue, since upstream has no source tree to target). Commit messages: imperative title, body explaining bug, mechanism, fix and tests. Never commit `build/`.

## Importing a new upstream release

Drop the asset in `build/`, extract it next to the previous one, generate the diff (`git diff --no-index old new`, strip the `old/`/`new/` prefixes), `git apply --check` then apply on `main` as a single "Importe les changements upstream …" commit, and run `./check.sh`. After applying, the tree must be byte-identical to the new archive except for locally modified files. Note that upstream file names and versions disagree (`ReDeFin_0.9.7_final.fbxqml` declares `0.9.6` in `manifest.json` and `clientId.js`).
