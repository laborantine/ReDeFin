# Contributing to ReDeFin

ReDeFin is a Jellyfin client for the Freebox Player (Révolution / Delta),
written in QML (QtQuick 2.15) and QML-flavoured JavaScript (`.pragma library`
modules). This document explains how to set up a development environment,
run the checks and tests, build a package, and run the application directly
on a Freebox Player with live console output.

Everything below works on Linux (including WSL2) **without root access and
without a system-wide Qt installation**.

## Table of contents

1. [How the Freebox QML platform works](#how-the-freebox-qml-platform-works)
2. [Prerequisites](#prerequisites)
3. [One-time setup](#one-time-setup)
4. [Running the checks and tests](#running-the-checks-and-tests)
5. [Writing tests](#writing-tests)
6. [Building a package](#building-a-package)
7. [Running on a Freebox Player (developer mode)](#running-on-a-freebox-player-developer-mode)
8. [Coding conventions](#coding-conventions)
9. [Commits and pull requests](#commits-and-pull-requests)
10. [Repository layout](#repository-layout)

## How the Freebox QML platform works

A few facts that shape the whole workflow:

- **There is no compilation step.** A `.fbxqml` package is a plain
  `tar.gz` of the source files listed in `ReDeFin.fbxproject`. The Player
  interprets the QML and JavaScript as-is at runtime. The package *is* the
  source code.
- **The Player runs Qt 5.15**, with Freebox-specific modules (`fbx.*`)
  provided by the firmware. The public
  [libfbxqml](https://github.com/fbx/libfbxqml) library (2014) provides
  `fbx.application`, `fbx.ui.base` and others for local tooling, but not
  `fbx.system`, which only exists on the Player.
- **Local tooling runs on Qt 6** (through the PySide6 wheels). It is good
  enough for syntax checking and for unit-testing logic and QML wiring, but
  it is not the Player: rendering, media playback and `fbx.system` are not
  covered. Always validate a change on a real Player before submitting it.
- The official SDK documentation lives at
  <https://dev.freebox.fr/sdk/player.html>. The packaging and remote-launch
  protocol are only documented by the source code of Free's
  [Qt Creator plugin](https://github.com/fbx/freebox-qtcreator-plugin) and
  [dev utils](https://github.com/fbx/freebox-dev-utils).

## Prerequisites

| Tool | Purpose | Notes |
|---|---|---|
| Bash, GNU tar, gzip | `build.sh`, `check.sh` | Standard on Linux |
| Python 3.9+ with `venv` and `pip` | Qt tooling venv, QML test runner, `fbx-run.py` | No root needed |
| Node.js 20+ | JS syntax check and unit tests (`node --test`) | Node 24 is used in CI-like runs |
| git | Fetching `libfbxqml` | |
| Network access to PyPI and GitHub | One-time setup only | ~150 MB for PySide6-Essentials |

Optional:

- `zeroconf` (Python package) for mDNS discovery of the Player. Not needed
  if you pass the Player's IP address explicitly.
- A Freebox Player (Révolution or Delta) on the same LAN with **developer
  mode enabled**, for on-device testing (see below).

## One-time setup

```bash
./tools/setup-qt-tools.sh
```

This single entry point:

1. creates a Python virtual environment in `~/.cache/redefin-qttools/venv`
   and installs `PySide6-Essentials`, which ships `qmllint`, the `qml`
   runner and the `QtTest` QML module;
2. runs `tools/fetch-libfbxqml.sh`, which clones the official `libfbxqml`
   library into `~/.cache/redefin-qttools/libfbxqml`.

Both locations can be overridden with the `REDEFIN_QT_VENV` and
`REDEFIN_LIBFBXQML` environment variables. The script is idempotent.

## Running the checks and tests

```bash
./check.sh
```

`check.sh` is the single command every commit must pass. It runs, in order:

1. **QML syntax lint** of every `.qml` file (`main.qml`, `qml/**`,
   `tests/**`) with `qmllint`. Only `[syntax]` errors fail the step: style
   warnings expected when Qt 6 tooling analyses Qt 5.15 code are ignored.
   `libfbxqml` and the local stubs are passed as import paths so that
   `fbx.*` imports resolve.
2. **JS syntax check** of every `qml/js/*.js` module with `node --check`, on
   a temporary copy where the `.pragma` and `.import` directives are
   neutralised.
3. **Node unit tests**: `tests/js/*.test.js`.
4. **Qt Quick Test** suites: `tests/qml/tst_*.qml`, run headless
   (`QT_QPA_PLATFORM=offscreen`) through `tests/qml/run_qml_tests.py`.
5. **Python unit tests** for the tooling: `tests/py/test_*.py`.

Useful options: `--no-lint`, `--no-tests`, `-h`. Exit code 0 means
everything passed, 1 means a check failed, 2 means a required tool is
missing (run `./tools/setup-qt-tools.sh`).

To run a single layer directly:

```bash
node --test tests/js/pressgesture.test.js
~/.cache/redefin-qttools/venv/bin/python3 tests/qml/run_qml_tests.py
python3 -m unittest discover -s tests/py -v
```

## Writing tests

Detailed guidance, with examples, is in [tests/README.md](tests/README.md).
In short:

- **Pure logic goes into a `.pragma library` module** in `qml/js/` and is
  tested with Node. `tests/js/qmljs.js` provides `loadQmlJs(path, {stubs})`,
  which evaluates a QML JavaScript module (resolving its `.import`
  directives) in a sandbox and returns its top-level functions and
  variables. Example: `qml/js/PressGesture.js` and
  `tests/js/pressgesture.test.js`.
- **QML wiring is tested with Qt Quick Test** (`TestCase` from
  `QtTest 1.2`). Real pages can be instantiated: `tests/qml/tst_profiletile.qml`
  loads the actual `qml/pages/LoginPage.qml`, injects a user model, and
  drives it with `keyPress` / `keyRelease`. Neutralise network access by
  leaving `serverUrl` empty and never assert on rendering.
- `tests/qml/stubs/` contains minimal stand-ins for modules that do not
  exist outside the Player (`fbx.system` with its `Device` singleton) or
  outside Qt 5 (`QtGraphicalEffects`). Extend them if a page you test uses
  a property they do not expose yet.
- Tooling scripts in `tools/` are tested with the Python standard library
  `unittest` in `tests/py/`, against local fakes (no network).

Prefer extracting a pure function over testing through the UI: it runs in
milliseconds and does not depend on Qt.

## Building a package

```bash
./build.sh
```

Produces `build/ReDeFin_<version>.fbxqml`, where the version is read from
`manifest.json`. The script:

- mirrors the file whitelist declared in `ReDeFin.fbxproject` (entry point
  at the root, `qml/components`, `qml/pages`, `qml/js`, `qml/images`,
  `qml/components/qmldir`, `manifest.json`, and the `.fbxproject` itself).
  **If you add a directory to `ReDeFin.fbxproject`, update the list in
  `build.sh` too**;
- validates `manifest.json` the way Free's packager does (valid JSON,
  `identifier` shaped like `com.example.app`, every entry point file
  present in the package, `uiFlavor` in `multi|classic`);
- writes a reproducible `ustar` + `gzip -n` archive (set
  `SOURCE_DATE_EPOCH` for byte-identical rebuilds).

Options: `-o <file>` to choose the output path, `-v <reference.fbxqml>` to
compare file lists and per-file SHA-256 against a reference package (useful
to prove that a repackaging changed nothing). `build/` is git-ignored.

The resulting file can be uploaded to the FreeStore through Free's
[FreeFactory](https://dev.freebox.fr/sdk/player.html) console, or side-loaded
on a Player in developer mode.

## Running on a Freebox Player (developer mode)

This is the fastest way to test a change: no package, no upload, and you
get the Player's console output (QML errors, network traces) in your
terminal.

### 1. Enable developer mode on the Player

On the Freebox Player, go to **Réglages > Système > Mode développeur**
(Settings > System > Developer mode) and enable it. Once enabled, the Player advertises a
`_fbx-devel._tcp.local.` mDNS service ("Remote debugger") and accepts
remote-launch requests on its HTTP port 80. The Freebox Pop runs Android TV
and is not concerned.

### 2. Make sure the Player can reach your machine

The Player downloads the sources over HTTP from your computer, so your
computer must be reachable from the LAN on the chosen port (default 8234).

- Native Linux: usually nothing to do, unless a local firewall blocks
  inbound TCP on that port.
- **WSL2**: the default NAT mode does not expose WSL to the LAN. Switch to
  mirrored networking (`networkingMode=mirrored` in `%UserProfile%\.wslconfig`,
  then `wsl --shutdown`), **and** allow inbound traffic through the Hyper-V
  firewall, which blocks it by default. In an administrator PowerShell:

  ```powershell
  New-NetFirewallHyperVRule -Name "ReDeFin-fbx-run" -DisplayName "ReDeFin fbx-run (WSL)" -Direction Inbound -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -Protocol TCP -LocalPorts 8234 -Action Allow
  ```

  Other options are described in [tools/README.md](tools/README.md).

### 3. Launch

```bash
python3 tools/fbx-run.py -t <player-ip> -v
```

The script serves the repository over HTTP, asks the Player to start the
`main` entry point of `manifest.json`, then relays the Player's standard
output and error streams to your terminal, prefixed `[out]` and `[err]`.
`-v` also logs every file the Player fetches. Press `Ctrl-C` to stop
relaying; the application keeps running on the TV.

Without `-t`, the script tries mDNS discovery (requires the `zeroconf`
package: `pip install zeroconf`).

A successful start looks like this:

```
Serveur HTTP local démarré sur http://192.168.1.10:8234/ (...)
[serveur] 192.168.1.20 - "GET /manifest.json HTTP/1.1" 200 -
Application démarrée : qml_port=32950 stdout_port=32988 stderr_port=32989
[err] ▊ [0.231] GET 200 http://192.168.1.10:8234/main.qml 14578
```

Messages you can ignore: `GET 404 .../qmldir` (the QML engine probes every
imported directory) and `Application instance does not declare a
handleUrl() function` (no `urlHandler` in the manifest).

If the Player answers `Failed to load application manifest from network:
Timeout, check your firewall`, the JSON-RPC call worked but the Player could
not reach your HTTP server: revisit step 2.

### Application traces (`DevLog`)

ReDeFin's historical logging module (`qml/js/SafeLog.js`) is neutralised in
the public build. Diagnostic traces go through `qml/js/DevLog.js` instead:

```js
DevLog.log("T8", "loader ARM reason=" + reason)
DevLog.log("T5", "url=" + DevLog.maskUrl(url))   // never log a raw URL
```

`DevLog.ENABLED` is `false` in the repository and in every package, so
`log()` does nothing for end users. `tools/fbx-run.py` serves that one file
with the flag switched to `true` on the fly (nothing is written to disk), so
traces appear **only during a developer-mode run**, as
`[err] … qml: DevLog: [RDF] <tag> <message>` (the Player names the file that
calls `console.log`, so always `DevLog`; the tag identifies the origin). Pass `--no-dev-log` to run
exactly like the public package. `build.sh` refuses to package the file if
the flag is not `false`, and a Node test enforces the same.

Rules: mask every URL with `DevLog.maskUrl()`; every identifier used in a
message must be in scope (an exception in the playback paths breaks
playback); in hot paths guard the call with `if (DevLog.ENABLED)` so the
message is not even built on the Révolution.

QML engine errors and the Player's own network traces are always reported,
with or without `DevLog`. The Player logs full request URLs, and stream URLs
carry `ApiKey=`: mask tokens before sharing a log.

## Coding conventions

- **QML and JS under `qml/` stay ES5**: no `let`, `const`, arrow functions,
  template strings or classes. The Player's Qt 5.15 engine would accept
  some of them, but the codebase is uniformly ES5; keep it that way.
- No `QtQuick.Controls`: the UI is built from `QtQuick` primitives and
  `fbx.ui.base`.
- No direct `console.log` in `qml/**`: use `DevLog.log()` (see
  [Application traces](#application-traces-devlog)), which is inert outside a
  developer-mode run.
- Comments in the application code are written in French, matching the
  existing code. Tests and tooling may use either language; this file and
  commit messages aimed at upstream are in English or French as you prefer.
- Business rules that can be expressed as pure functions belong in a
  `.pragma library` module with no global mutable state, so they can be
  unit-tested with Node and shared between pages (see
  `qml/js/PressGesture.js`, used by both `LoginPage.qml` and
  `ServerOverlay.qml`).
- Keep in mind the Freebox Révolution is a low-power device: avoid
  per-frame shader effects, unbounded model rebuilds and large synchronous
  JSON work on the GUI thread.

## Commits and pull requests

- **One logical change per commit**, and every commit must pass
  `./check.sh`. This keeps the history bisectable and lets each fix be
  submitted upstream on its own.
- Each behavioural change should come with a test: a Node test for the
  pure logic, and a Qt Quick Test when the QML wiring changed.
- Commit messages: a short imperative title, a body explaining the bug, the
  mechanism, the fix and how it was tested.
- Before opening a pull request, run `./check.sh`, rebuild with
  `./build.sh`, and if possible run the change on a Player with
  `tools/fbx-run.py`. Mention in the PR what was verified on device.
- Never commit `build/` or generated packages.

The upstream repository is <https://github.com/laborantine/ReDeFin>
(GPL-3.0). At the time of writing it publishes its sources only as
`.fbxqml` release assets, so contributions may need to be offered as
patches (`git format-patch`) attached to an issue rather than as a
conventional pull request.

## Repository layout

```
main.qml                 Application entry point (fbx.application.Application)
manifest.json            FreeStore manifest (identifier, version, entry points)
ReDeFin.fbxproject       Qt Creator / packager file: whitelist of packaged files
qml/components/          Reusable QML components (+ qmldir for singletons)
qml/pages/               Screens (login, home, details, player overlays…)
qml/js/                  QML JavaScript libraries (.pragma library modules)
qml/images/              Packaged images
build.sh                 Builds the .fbxqml package (+ manifest validation)
check.sh                 Lint + all test layers; must pass on every commit
tools/setup-qt-tools.sh  One-time setup (PySide6 venv + libfbxqml)
tools/fetch-libfbxqml.sh Clones the official Freebox QML library
tools/fbx-run.py         Runs the app on a Player in developer mode
tools/README.md          Details and troubleshooting for fbx-run.py
tests/js/                Node tests + loader for QML JS modules
tests/qml/               Qt Quick Test suites, runner and fbx.* stubs
tests/py/                Tests for the Python tooling
tests/README.md          How to write tests
build/                   Generated packages (git-ignored)
```
