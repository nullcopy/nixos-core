# VPNs

Account setup and daily commands for the VPNs nixos-core can enable.
Every command runs on the machine, as the admin user.

VPN membership is machine policy; only the admin configures it, and a
login works without any VPN credentials.

- **NymVPN** is the machine's default route once the admin runs
  `nym-vpnc connect`; nothing connects at boot.
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

## tailscale (`core.tailscale.enable`)

Enroll and connect manually:

```sh
sudo tailscale up --login-server=https://your.headscale.example
sudo tailscale down                                # when done
```

The first `up` prints an auth URL (or pass `--auth-key=tskey-…` from
`headscale preauthkeys create`); tailscaled stores the enrollment, so
later `up` commands connect immediately.
