# Security and system changes

## What LabRoute touches

- **Proxy settings** of the network services you select: it enables *Automatic proxy configuration* with a URL `http://127.0.0.1:<port>/proxy.pac`. Before changing anything, it writes the previous settings to `~/Library/Application Support/LabRoute/proxy-restoration.json`. Disconnect restores exactly those settings, and only if they are still the ones LabRoute applied. Changes made by other tools are never overwritten.
- **Local listeners**: the PAC file and the SSH SOCKS port listen on `127.0.0.1` only. The CLI talks to the app over a private per-user Unix socket.
- **SSH**: `/usr/bin/ssh -D 127.0.0.1:<port> -N` with an isolated LabRoute known_hosts file, strict host-key checking, no agent forwarding, and public-key authentication only.
- **Keychain**: the passphrase of a LabRoute-created key is stored in your login Keychain (service `org.labroute.keys`). Account passwords are used once during setup and never stored.
- **Files**: `~/Library/Application Support/LabRoute/` (configuration, restoration record, SSH key/known_hosts). No logs of visited sites, no analytics, no network calls other than your SSH connection.

## Manual recovery

If the app is gone but proxy settings remain: System Settings → Network → *service* → Details → Proxies → turn off **Automatic proxy configuration**. Then delete `~/Library/Application Support/LabRoute/proxy-restoration.json`, and stop a leftover tunnel with `pkill -f "ssh .*-D 127.0.0.1"` if one is still running.

## Uninstall

Disconnect and Quit, then delete `~/Applications/LabRoute.app` and `~/Library/Application Support/LabRoute/`. Optionally remove the `org.labroute.keys` Keychain item and the `LabRoute` line from the server's `~/.ssh/authorized_keys`.

## Reporting

Please open a GitHub issue. Don't include hostnames, usernames, keys or configuration files.
