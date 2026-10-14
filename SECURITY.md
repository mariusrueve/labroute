# Security and system changes

## What LabRoute touches

- **Proxy settings** of the network services you select: it enables *Automatic proxy configuration* with a URL `http://127.0.0.1:<port>/proxy.pac`. Before changing anything, it writes the previous settings to `~/Library/Application Support/LabRoute/proxy-restoration.json`. Disconnect restores exactly those settings, and only if they are still the ones LabRoute applied. Changes made by other tools are never overwritten.
- **Local listeners**: the PAC file, the SSH SOCKS port (1080) and the terminal HTTP proxy (1081, while the app runs) listen on `127.0.0.1` only. Like any loopback port, other local processes can reach them. The terminal proxy sends routed domains through the tunnel and everything else directly; it never logs hosts or contents. The CLI talks to the app over a private per-user Unix socket.
- **SSH**: `/usr/bin/ssh -D 127.0.0.1:<port> -N` with an isolated LabRoute known_hosts file, strict host-key checking, no agent forwarding, and public-key authentication only.
- **Keychain**: the passphrase of a LabRoute-created key is stored in your login Keychain (service `org.labroute.keys`). Account passwords are used once during setup and never stored.
- **Files**: `~/Library/Application Support/LabRoute/` (configuration, restoration record, SSH key/known_hosts). No logs of visited sites, no analytics, no network calls other than your SSH connection.
- **Terminal integration** (only when you add SSH hosts or click *Add*): LabRoute writes `~/.ssh/labroute/config` and never overwrites a file there that it did not generate. *Add* puts one `Include` line at the top of `~/.ssh/config` and one line at the end of `~/.zshrc`, after copying each file to `*.labroute-backup`. *Remove* deletes exactly those lines. Symlinked files are never edited.
- **Lab setup files** (*Export…* / *Import…* on the Connection tab): plain JSON with the server name, institution, your own domains and ssh host names, aliases and ports. Usernames, key paths, identity files and extra ssh options are never written or read, so an imported file cannot add ssh options that run commands. Import only adds missing entries.

## Manual recovery

If the app is gone but proxy settings remain: System Settings → Network → *service* → Details → Proxies → turn off **Automatic proxy configuration**. Then delete `~/Library/Application Support/LabRoute/proxy-restoration.json`, and stop a leftover tunnel with `pkill -f "ssh .*-D 127.0.0.1"` if one is still running.

## Uninstall

First click *Remove* for both lines on the **Terminal** tab. With Homebrew: `brew uninstall --cask --zap labroute`. From source: quit LabRoute, then delete `~/Applications/LabRoute.app`, `~/Library/Application Support/LabRoute/` and `~/.ssh/labroute/`. Leftover lines are harmless: ssh ignores an `Include` of a missing file, and the `~/.zshrc` line only runs while LabRoute is installed. Optionally remove the `org.labroute.keys` Keychain item and the `LabRoute` line from the server's `~/.ssh/authorized_keys`.

## Reporting

Please open a GitHub issue. Don't include hostnames, usernames, keys or configuration files.
