# VPNs

Account setup and daily commands for the VPNs nixos-core can enable.
Every command runs on the machine, as the admin user.

VPN membership is machine policy; only the admin configures it, and a
login works without any VPN credentials.

- **NymVPN** is the machine's default route once the admin runs
  `nym-vpnc connect`; nothing connects at boot.
- **Obscura** is the machine's default route once the admin runs
  `obscura connect`; nothing connects at boot. A machine enables NymVPN
  or Obscura, not both.
- **tailscale** carries tailnet destinations (`100.64.0.0/10`, MagicDNS)
  only, and only after the admin runs `sudo tailscale up`.

## NymVPN (`core.nymvpn.enable`)

Store the machine account once:

```sh
read -rs MNEMONIC                  # paste the account mnemonic (stays out of shell history)
nym-vpnc account set "$MNEMONIC"   # stored daemon-side, machine-wide
```

Connect after every boot; the daemon keeps the tunnel up from there,
across network changes, until a disconnect or a shutdown:

```sh
nym-vpnc connect --wait
nym-vpnc status
nym-vpnc disconnect                # when done
```

Gateway selection can retry for minutes on a bad start; `journalctl -u
nym-vpnd` shows what it is doing.

## Obscura (`core.obscura.enable`)

The daemon's socket is open to group `obscura`; every wheel user is a
member. Store the machine account once:

```sh
obscura login                      # prompts for the account number; stored daemon-side, machine-wide
```

Connect after every boot. `connect` returns once the tunnel is up and
the daemon keeps it up from there, across network changes, until a
disconnect or a shutdown:

```sh
obscura connect
obscura status
obscura disconnect                 # when done
```

The daemon's kill switch exists only while it connects or is connected.
Before the first `connect` and after a `disconnect`, traffic leaves the
machine outside the tunnel. `journalctl -u obscura` shows what the
daemon is doing.

## tailscale (`core.tailscale.enable`)

Enroll and connect manually:

```sh
sudo tailscale up --login-server=https://your.headscale.example
sudo tailscale down                                # when done
```

The first `up` prints an auth URL (or pass `--auth-key=tskey-…` from
`headscale preauthkeys create`); tailscaled stores the enrollment, so
later `up` commands connect immediately.
