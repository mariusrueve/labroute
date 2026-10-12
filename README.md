# LabRoute

A small native macOS menu-bar app that sends **selected websites** through an SSH connection to your lab or university server. You can reach internal lab pages and use your institution's journal subscriptions without installing a full VPN client.

```text
Selected domain   → browser → local PAC file → SSH SOCKS tunnel (/usr/bin/ssh -D) → lab server → website
Everything else   → DIRECT (your normal connection)
```

- Native Swift/SwiftUI, no dependencies, no background daemon, no kernel or network extension.
- Uses the system `/usr/bin/ssh` with a dedicated encrypted key stored in your Keychain.
- About 50 publisher domains (Elsevier/ScienceDirect, Springer Nature, Wiley, ACS, RSC, IEEE, ACM, APS, IOP, Taylor & Francis, SAGE, JSTOR, OUP, Cambridge, Science, PNAS, …) are built in. Toggle any of them, and add your own internal sites.
- Disconnect (or Quit) restores your previous proxy settings exactly.

## Requirements

- macOS 15 or newer, tested on Apple Silicon.
- Safari, Google Chrome or Brave. They all follow the macOS system proxy settings, which LabRoute manages. Firefox works only if you set *Settings → Network Settings → Use system proxy settings*.
- An SSH account on a server inside your institution's network.
- Apple's Command Line Tools to build it: `xcode-select --install`. Full Xcode is not needed.

## Install

```bash
git clone https://github.com/mariusrueve/labroute.git
cd labroute
bash scripts/install.sh
open ~/Applications/LabRoute.app
```

The app is ad-hoc signed, not notarized. If macOS blocks it, allow it once under **System Settings → Privacy & Security → Open Anyway**.

To update, choose **Disconnect and Quit** from the menu, then `git pull` and run `bash scripts/install.sh` again. After an update, macOS may ask once whether LabRoute may use its Keychain item; choose **Always Allow**.

## First-time setup

1. Open LabRoute. The window opens with **SSH setup** expanded.
2. Enter a name for your institution, the SSH hostname, the port (usually 22) and your username.
3. Either choose an existing private key, or let LabRoute create a dedicated encrypted key. In that case it asks for your account password **once** to add the public key to `~/.ssh/authorized_keys` on the server. The password is not stored.
4. Confirm the server's host key and click **Set Up and Verify SSH**.
5. Under **Network services**, tick the connection you use (Wi-Fi and/or Ethernet).
6. Add your internal sites under **Routed domains** (e.g. `intranet.uni-example.de`). Subdomains are included automatically.

## Daily use

- Click the menu-bar icon → **Connect**. macOS asks for your admin password to change the proxy settings, and the Keychain may ask for the key passphrase.
- When the icon shows a shield, you're connected. **Quit and reopen your browser once** (⌘Q). Browsers keep their existing connections to sites and won't route them through LabRoute until they restart. Then open papers and internal pages as usual.
- You can add or toggle domains while connected. Reload the page; if the browser keeps using the old route, restart it.
- **Disconnect** restores your previous proxy settings. **Disconnect and Quit** (⌘Q) does the same and exits.
- Optional: *Preferences → Launch at login* and *Connect automatically*.

A command-line client is bundled for scripting the running app:

```bash
~/Applications/LabRoute.app/Contents/MacOS/labroute status --json
~/Applications/LabRoute.app/Contents/MacOS/labroute connect --wait
~/Applications/LabRoute.app/Contents/MacOS/labroute route add intranet.uni-example.de
~/Applications/LabRoute.app/Contents/MacOS/labroute disconnect --wait
```

## Troubleshooting

- **"Existing proxy or PAC settings conflict"**: the selected network service already has a proxy configured. LabRoute refuses to overwrite it. Remove it in System Settings → Network → *service* → Details → Proxies, or select another service.
- **"Restoration record found"** after a crash or forced quit: open LabRoute and click **Disconnect** (restores your settings) or **Reconnect Recorded Session**.
- **"Network settings changed outside LabRoute"**: something else edited the proxy settings while you were connected. LabRoute won't overwrite them. Check System Settings → Network → Proxies and turn off *Automatic proxy configuration* if it still points to `http://127.0.0.1:…/proxy.pac`, then click Disconnect again.
- **Page still paywalled**: restart the browser first. Publisher sites show your institution's name (e.g. "Access provided by …") when routing works. Old archive volumes may not be covered by your library's licence. Also check that the publisher's domain is enabled. Some sites load content or log-in from a second domain, which you can add under *Custom*. Then reload or restart Safari.
- Check what macOS currently uses with `scutil --proxy`.

## Limitations

- This is a best-effort access helper, **not a VPN or a privacy tool**. Only the listed domains are tunnelled. If the local PAC file becomes unavailable, the browser may fall back to a direct connection.
- Only applications that honour the macOS system proxy (PAC) settings are covered: Safari, Chrome, Brave and other Chromium browsers that use system settings. A browser extension or policy that sets its own proxy overrides LabRoute. Other tools need their own SOCKS5 setting (`127.0.0.1:1080` while connected).
- Each user needs their own SSH account and must follow their institution's terms of use for licensed content.

## Development

```bash
swift build
bash scripts/test.sh                 # unit and controller tests (no system changes)
bash scripts/build-app.sh debug      # dist/LabRoute Development.app
bash scripts/build-app.sh release    # dist/LabRoute.app
```

Code layout: `Sources/LabRouteCore` (domains, route packs, PAC generation), `Sources/LabRouteServices` (controller, SSH supervision, PAC server, proxy transactions), `Sources/LabRouteApp` (SwiftUI), `Sources/LabRouteCLI`, `Sources/LabRouteAskPass` (credential bridge for `ssh`). The built-in publisher list is in `Sources/LabRouteCore/Resources/route-packs.json`.

See [SECURITY.md](SECURITY.md) for what LabRoute changes on your system. Licensed under [Apache-2.0](LICENSE).
