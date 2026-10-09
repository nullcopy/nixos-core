# VPNs

Account setup and daily commands for the VPNs nixos-core can enable.
Every command runs on the machine, as the admin user.

VPN membership is machine policy; only the admin configures it, and a
login works without any VPN credentials.

- **NymVPN** is the machine's default route; the tunnel starts at every
  boot, before any login.
- **tailscale** carries tailnet destinations (`100.64.0.0/10`, MagicDNS)
  only, and only after the admin runs `sudo tailscale up`.

## NymVPN (`core.nymvpn.enable`)

Store the machine account once, then restart the service; every later
boot connects automatically:

```sh
read -rs MNEMONIC                  # paste the account mnemonic (stays out of shell history)
nym-vpnc account set "$MNEMONIC"   # stored daemon-side, machine-wide
sudo systemctl restart nym-vpn-autoconnect
nym-vpnc status
```

`sudo systemctl stop nym-vpn-autoconnect` disconnects until the next
boot.

## tailscale (`core.tailscale.enable`)

Enroll and connect manually:

```sh
sudo tailscale up --login-server=https://your.headscale.example
sudo tailscale down                                # when done
```

The first `up` prints an auth URL (or pass `--auth-key=tskey-…` from
`headscale preauthkeys create`); tailscaled stores the enrollment, so
later `up` commands connect immediately.
