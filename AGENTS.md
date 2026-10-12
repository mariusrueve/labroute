# LabRoute contributor notes

Personal macOS menu-bar tool: routes selected domains (lab intranet, journal publishers) through an SSH SOCKS tunnel via a loopback PAC file. Target: Safari, Chrome and Brave on macOS 15+. The PAC directive `SOCKS5 h:p; SOCKS h:p` is deliberate: CFNetwork reads it as SOCKS5, Chromium uses SOCKS5 with remote DNS. Keep it small and working; no process/beta/release-gate paperwork.

## Layout

- `Sources/LabRouteCore`: value models, domain validation, route packs (`Resources/route-packs.json`), PAC generation.
- `Sources/LabRouteServices`: `ApplicationController` (shared by GUI and CLI IPC), SSH supervision, loopback PAC server, proxy transactions/journal, configuration store, fixture test doubles.
- `Sources/LabRouteApp`: SwiftUI menu bar and window over the controller.
- `Sources/LabRouteCLI`: IPC client for the running app; never starts SSH itself.
- `Sources/LabRouteAskPass`: private credential bridge for `ssh`; never log secrets.

## Commands

```bash
swift build
bash scripts/test.sh              # all tests; uses fixtures, never touches real settings
bash scripts/test.sh -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG  # same, optimized
bash scripts/build-app.sh release # dist/LabRoute.app
bash scripts/install.sh           # build + install to ~/Applications
```

Command Line Tools only (no Xcode): SwiftUI macros like `@State` are unavailable. Use `@Published` on the model instead.

## Invariants

- Swift 6 strict concurrency; no external dependencies; process execution uses explicit paths and argument arrays.
- Write the restoration journal before changing system proxy settings. Restore only settings LabRoute still owns; on conflict keep the journal and report it.
- PAC/SOCKS/IPC listeners are loopback-only or private per-user sockets.
- Never persist account passwords; private keys never go into configuration JSON.
- No telemetry, request logging, TLS interception or custom CAs.
- Never commit hostnames, usernames, keys or personal configuration.
- Tests must use `FixtureEnvironment` / fake preferences, never real network settings.

## Releases (Homebrew)

Users install with `brew install --cask mariusrueve/tap/labroute`. To release, commit to `main` with CI green, then:

```bash
git tag v1.2.3 && git push origin v1.2.3
```

`.github/workflows/release.yml` then:
- runs the tests
- builds a universal app, taking the version from the tag via `build-app.sh --version`, so don't edit `Info.plist` by hand
- publishes `LabRoute-1.2.3.zip` as a GitHub Release
- bumps `version` and `sha256` in `Casks/labroute.rb` of `mariusrueve/homebrew-tap`

The tap update needs the `TAP_TOKEN` repository secret: a fine-grained PAT with Contents read/write on `homebrew-tap` only. Without it, the release still publishes and the workflow warns.

## README screenshot

`docs/screenshot.png` comes from the development app in fixture mode (example data only, never real settings): build with `bash scripts/build-app.sh debug`, write a demo `configuration.json` into a new fixture root, run `open -n "dist/LabRoute Development.app" --args --fixture <UUID> --snapshot <png>`, then run `labroute --fixture <UUID> connect --wait`. The app saves its own window after 6 seconds.
