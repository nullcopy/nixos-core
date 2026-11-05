# VPNs

Account setup and daily commands for the VPNs nixos-core can enable.
Every command runs on the machine, as the admin user.

VPN membership is machine policy; only the admin configures it, and a
login works without any VPN credentials.

- **NymVPN** is the machine's default route once the admin runs
  `nym-vpnc connect`; nothing connects at boot, and the machine has no
  network egress until that first connect.
- **Obscura** is the machine's default route once the admin runs
  `obscura connect`; nothing connects at boot, and the machine has no
  network egress until that first connect. A machine enables NymVPN or
  Obscura, not both.
- **WireGuard exit** is a full tunnel to a relay you run. It is set up
  in the machine config and comes up at boot, so there is no connect
  step; a boot gate blocks every other destination until the handshake
  succeeds and keeps blocking them afterwards.
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

The daemon installs its firewall only once a connect is requested.
Before that the `nym-vpn-gate` unit blocks all egress except the
daemon's own traffic, tailscale's tunnel traffic, DHCP, IPv6 neighbor
discovery and the local network; it lifts once the tunnel is up and
stays lifted until the next boot, so a `disconnect` leaves traffic
outside the tunnel. Name lookups are blocked for everything but the
daemon, so `sudo tailscale up` against a hostname needs the tunnel up
or the gate lifted. A failed `connect` leaves the gate in place.

To lift the gate without connecting, for the rest of the boot:

```sh
sudo systemctl stop nym-vpn-gate
```

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
Before the first `connect` the `obscura-gate` unit blocks all egress
except the daemon's own traffic, tailscale's tunnel traffic, DHCP, IPv6
neighbor discovery and the local network; it lifts once the tunnel is
up and stays lifted until the next boot, so a `disconnect` leaves
traffic outside the tunnel. Name lookups are blocked, the daemon's
included: it connects from a cached API address, and if that goes
stale, `login` and `connect` fail until the gate is lifted. `sudo
tailscale up` against a hostname also needs the tunnel up or the gate
lifted. A failed `connect` leaves the gate in place; `journalctl -u
obscura` shows what the daemon is doing.

To lift the gate without connecting, for the rest of the boot:

```sh
sudo systemctl stop obscura-gate
```

## WireGuard exit (`core.wireguardExit.enable`)

A full tunnel to a relay you run. Unlike NymVPN and Obscura there is no
third-party service and no daemon: the interface is set up by NixOS at
boot, and the boot gate stays up for the machine's lifetime rather than
until the tunnel is up. Everything leaves through the tunnel except the
relay's own address, the LAN and link-local traffic.

The machine needs, in `configuration.nix`:

```nix
core.wireguardExit.enable = true;
core.wireguardExit.address = "10.99.99.7/24";             # this machine's tunnel address
core.wireguardExit.relay.publicKey = "…";                 # the relay's public key
core.wireguardExit.relay.endpoint = "203.0.113.10:51820"; # the relay's address and port
core.wireguardExit.dns = "10.99.99.1";                    # the relay's resolver
```

`interface` defaults to `wg0`, and `privateKeyFile` to
`/etc/wireguard/<interface>.key`, which is where the install script
puts the key; set `privateKeyFile` only if you place the key somewhere
yourself. The address, the relay's public key and the endpoint have no
defaults; enabling the module without them fails the build with a
message naming what is missing.

The endpoint must be a literal address — `203.0.113.10:51820` for IPv4,
`[2001:db8::1]:51820` for IPv6. A hostname would have to be resolved
before the gate lets anything out, and the gate drops DNS.

### The relay side

There is no relay module. Any machine that can run WireGuard serves:
give it a keypair first, since clients need its public key, and its
`configuration.nix` uses `networking.wireguard.interfaces` directly,
with one host-route peer per client:

```sh
sudo install -d -m 700 /etc/wireguard
wg genkey | sudo tee /etc/wireguard/wg0.key >/dev/null
sudo chmod 600 /etc/wireguard/wg0.key
sudo wg pubkey < /etc/wireguard/wg0.key    # what clients set as relay.publicKey
```

```nix
networking.wireguard.interfaces.wg0 = {
  ips = [ "10.99.99.1/24" ];  # the relay's address on the tunnel network
  privateKeyFile = "/etc/wireguard/wg0.key";
  listenPort = 51820;
  peers = [
    { publicKey = "…"; allowedIPs = [ "10.99.99.7/32" ]; }  # one line per client
  ];
};

# Nothing opens the WireGuard port for you. Without this the relay drops
# the handshake, and the client's gate holds for good.
networking.firewall.allowedUDPPorts = [ 51820 ];
```

and forwards and masquerades the clients' traffic:

```nix
boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;
networking.nat = {
  enable = true;
  externalInterface = "eth0";  # the relay's uplink
  internalInterfaces = [ "wg0" ];
};
```

The relay's own resolver is what clients point `core.wireguardExit.dns`
at.

### Key generation and ordering

When the machine config enables the exit, the install script asks for
whatever the config leaves out — the tunnel address, the relay's public
key (`sudo wg show wg0 public-key` on the relay) and the relay's
endpoint — writes the answers into `configuration.nix`, generates the
client key on the target root, and prints the peer line the relay
needs, a host route for the client's tunnel address (`/32` for IPv4,
`/128` for IPv6):

```nix
{ publicKey = "…"; allowedIPs = [ "10.99.99.7/32" ]; }
```

A key already at `/etc/wireguard/<interface>.key` is kept and reused,
and the printed stanza is derived from it, so a key restored during the
review shell keeps the machine's identity and the relay's existing entry
stays valid.

**Register that line in the relay's repo and rebuild the relay before
the machine's first boot.** The gate is up from early boot and only
lets the handshake out; without a matching peer there is no handshake
and the machine has no network egress at all. The gate's journal says so
three minutes in:

```sh
journalctl -u wireguard-exit-gate
```

To generate the key by hand, or to replace one:

```sh
sudo wg genkey | sudo tee /etc/wireguard/wg0.key >/dev/null
sudo chmod 600 /etc/wireguard/wg0.key
sudo wg pubkey < /etc/wireguard/wg0.key  # paste into the relay's peer
```

### Tunnel addresses

The relay's repo is the registry of tunnel addresses. Give each client
its own address in the tunnel subnet and a matching host route in the
relay's peer list (`/32` for IPv4, `/128` for IPv6); two clients with
one address break both. The relay can assert uniqueness over its peer
list.

### The gate

`wireguard-exit-gate` installs an nftables table before any interface
exists and keeps it. It allows loopback; the tunnel interface; the
relay's address and port, so the handshake can leave first; tailscale
(its tun device and its marked underlay traffic); the LAN ranges
(`10/8`, `172.16/12`, `192.168/16`, `169.254/16`, the multicast ranges
and the IPv6 equivalents); and link-scope DHCP and IPv6 neighbour
discovery. It drops everything else, DNS included.

Because the table stays, nothing leaves the physical link after the
tunnel comes up either: a service bound to the physical interface's
address is dropped, not just routed past. IPv6 enters the tunnel too
(`::/0` is in the relay's AllowedIPs), so a relay that does not route
IPv6 fails closed rather than leaking.

To lift the gate by hand, for the rest of the boot:

```sh
sudo systemctl stop wireguard-exit-gate
```

The unit's `ExecStopPost` touches `/run/wireguard-exit-gate.lifted`,
and `ConditionPathExists` keeps the gate down until the next boot.

Gate rules change at the next boot only: `restartIfChanged = false`
keeps the running table across a rebuild, and the lifted marker blocks a
manual restart. After changing `relay.endpoint` or `interface`, the old
carve-out stays until you reboot, dropping handshakes to the new
address. To apply the change sooner, stop the unit (which deletes the
table and sets the marker), clear the marker, and start it again:

```sh
sudo systemctl stop wireguard-exit-gate
sudo rm /run/wireguard-exit-gate.lifted
sudo systemctl start wireguard-exit-gate
```

### DNS

With `core.wireguardExit.dns` set, systemd-resolved takes the relay's
resolver as its default route for DNS, so lookups leave through the
tunnel. It is not the only route: a search domain the link learned from
DHCP claims its own names and sends them to the local resolver, which
the gate drops, so those lookups fail rather than leak. `resolvectl
status` shows which resolver serves a name; a link that contributes DNS
servers and search domains should be told not to (NetworkManager:
`networking.networkmanager.dns = "none"`), leaving the global route as
the only one. Without `dns`, the machine resolves through whatever the
link provided, and the gate drops those queries: name resolution fails.

### Troubleshooting

```sh
sudo wg show                               # interface, peers, latest handshake
sudo systemctl status wireguard-wg0        # the interface unit
sudo systemctl status wireguard-exit-gate  # the boot gate
sudo journalctl -u wireguard-wg0 -u wireguard-exit-gate
ip rule show                               # the relay carve-out and the tunnel table
ip route show table 51820                  # the tunnel default route
```

A `latest-handshakes` of zero everywhere means the relay never answered:
check that its peer list holds this machine's public key, and that the
endpoint address and port are right. Traffic that hangs with a healthy
handshake is usually DNS; see above. A machine that cannot reach
anything at all, the LAN included, has the gate down but no handshake —
`systemctl status wireguard-exit-gate`.

## tailscale (`core.tailscale.enable`)

Enroll and connect manually:

```sh
sudo tailscale up --login-server=https://your.headscale.example
sudo tailscale down                                # when done
```

The first `up` prints an auth URL (or pass `--auth-key=tskey-…` from
`headscale preauthkeys create`); tailscaled stores the enrollment, so
later `up` commands connect immediately.
