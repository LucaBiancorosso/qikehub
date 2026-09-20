# qikehub (lite)

Interactive installer that turns a small VPS into a **WireGuard hub**: phones and laptops
connect as roaming clients, an optional home router (e.g. RouterOS behind CGNAT) connects
in as a peer, and client traffic egresses either at the VPS or through the home site.
Management (SSH) is reachable **only through the tunnel** until you explicitly allow it.

This is the simplified sibling of [`../qikehub`](../qikehub) (the IKEv2/strongSwan version).
Same CLI name, same overall shape — wizard, `add-client`, `lockdown`, tunnel-only management —
but WireGuard removes almost everything that made the IPsec version hard to operate:

| | qikehub (IPsec) | qikehub (lite, this one) |
|---|---|---|
| Tunnel daemon | strongSwan (charon-systemd + swanctl) | none — WireGuard is a kernel module |
| Interfaces | 2x XFRM (`xfrm-rw`, `xfrm-home`) + dummy `mgmt0` | 1x `wg0` |
| Identity | Private CA, certs, CRL, revocation | static keypairs; revoke = delete the peer |
| Crypto | Configurable (AES-256-GCM/SHA-384/ECP-384, optional ML-KEM) | fixed: Curve25519 + ChaCha20-Poly1305 + BLAKE2s — no knobs |
| Client artefacts | `.mobileconfig` (Apple), `.sswan` (Android), `swanctl.conf` — three formats | one `.conf` + QR code, same format for every platform |
| Adding a client | reloads strongSwan + writes files | `wg syncconf` — **never touches the firewall or other peers** |
| Apple native port dance | yes (`PORT_MODE=hybrid`, UDP/500+4500 redirect) | no — WireGuard apps take any port directly |

What it does **not** try to replicate: post-quantum key exchange (WireGuard has no PQ
negotiation today), SNMP, and the confirm-or-rollback-on-every-reload paranoia the IPsec
version needed because reloading strongSwan/nftables together could desync conntrack —
here, adding/revoking a client never reloads the firewall at all.

## Design in one screen

| Area | Choice |
|---|---|
| OS | Debian 13 minimal, kernel WireGuard (in-tree since Linux 5.6 — no DKMS needed on a current kernel) |
| Auth | Static Curve25519 keypair per peer. Revoke = remove the peer, live, no CRL |
| Crypto | WireGuard's fixed suite: Curve25519, ChaCha20-Poly1305, BLAKE2s. Not configurable, by design |
| Public surface | One UDP port. Everything else dropped |
| Management | hub's own `wg0` address (first IP of the pool); nftables permits TCP/22 only from `wg0` |
| Egress | `vps` (masquerade) or `home` (policy-routed to the site peer — fail-closed: no live session, no route, no VPS fallback) |
| IPv6 | Client `.conf` always captures `::/0`; hub rejects (default) or NAT66s it — no leak either way |

## Requirements

- Any KVM/Xen/Cloud VPS with a current kernel (Linux ≥ 5.6). No XFRM/CONFIG_XFRM_INTERFACE
  requirement like the IPsec version — WireGuard works on effectively everything, including
  the smallest Hetzner Cloud instance.
- Debian 13 minimal, root, an SSH key already installed.
- DNS A record `vpn.example.com → VPS IPv4` (recommended; clients can also dial the raw IP).
- Provider firewall: UDP/`<port>` and TCP/22 from your IP until `lockdown`.

## Quick start

```bash
git clone https://github.com/LucaBiancorosso/qikehub && cd qikehub-lite
sudo ./qikehub install          # interactive; installs itself to /opt/qikehub
sudo qikehub add-client luca-iphone
sudo qikehub add-client luca-mac
sudo qikehub site-config        # if you enabled a home site → RouterOS script
# connect a client, then over the tunnel:
ssh root@10.99.0.1
sudo qikehub lockdown           # closes public SSH
```

On a brand-new install, public SSH stays reachable (from your detected client IP if you
connected over SSH, otherwise from anywhere — e.g. installing from a provider's web console)
until you run `lockdown`. Re-running `configure` later never reopens it on its own.

Firewall changes made over SSH apply with a 60-second confirm-or-rollback: open a **new**
SSH session, then type `ok`. This only happens on `install`/`configure`/`lockdown`/`allow-ssh`
— `add-client`/`revoke-client` never touch the firewall.

Progress messages (`[+] ...`) are off by default. Set `HUB_VERBOSE=1` for per-step confirmations.

Non-interactive: export any key from `examples/qikehub.env.example` and run with
`HUB_NONINTERACTIVE=1`.

## Commands

| Command | Purpose |
|---|---|
| `install` / `configure` | Wizard; re-run to change settings (current values become defaults) |
| `render` | Re-apply interface, WireGuard config, firewall from `/etc/qikehub/hub.conf` |
| `add-client NAME` | Issue a keypair; writes `NAME.conf` + a scannable QR code to `/var/lib/qikehub/out/NAME/` |
| `revoke-client NAME` | Remove the peer live (`wg set ... remove`) — no reload of anything else |
| `list-clients` | Issued peers + live handshake/transfer stats (`wg show`) |
| `site-config` | (Re)issue the home-site keypair + a RouterOS import script |
| `status` | Services, `wg show`, config summary |
| `lockdown [--force]` | Remove public SSH; refuses unless your session arrives on the hub's tunnel address |
| `allow-ssh CIDR[,CIDR]` | Temporarily re-open public SSH |

## Client onboarding

`add-client NAME` writes a standard WireGuard `.conf` and prints a QR code straight to the
console — point the WireGuard app's "scan" at your terminal and you're done, no file transfer
needed. It also saves a `.png` in case you'd rather AirDrop/scp it. Same file format for
iOS, Android, macOS, Windows and Linux — install the official WireGuard app, import or scan,
connect.

Client keys are generated on the hub, written into the delivered `.conf`, then the hub's own
copy of that private key is shredded — matching the "no client private key lingers on the hub"
rule from the IPsec version, just without needing a PKCS#12 dance to get there.

## Security notes

- **Crypto is not configurable.** This is intentional — WireGuard has one fixed, modern,
  widely-audited suite. If you need post-quantum key exchange today, that's the IPsec
  version's job (`PQ_MODE`), not this one.
- **Revocation is instant and live**: `wg set wg0 peer <pubkey> remove`, no reload of other
  peers, no firewall touch, no CRL propagation delay.
- **Host**: key-only sshd drop-in, unattended security upgrades, redirects off. `rp_filter`
  is only loosened (`2`, loose) when `EGRESS=home` actually needs the asymmetric path — left
  at Debian's default otherwise, on purpose, after a real debugging session on Hetzner Cloud
  where touching it unnecessarily was one of several suspects.
- **State & secrets**: `/etc/qikehub` (0700). `peers.tsv` holds public keys and assigned
  addresses only — never a private key. `.gitignore` blocks generated artefacts.

## Home site (RouterOS 7, native WireGuard)

`site-config` generates a `.rsc` that creates the WireGuard interface, peer, address, and
a route back to the client pool, plus (if `EGRESS=home`) a masquerade rule for client egress.
Unlike the IPsec version's RouterOS script, there's no certificate import dance and no
"unverified on a non-500 port" caveat — WireGuard on RouterOS 7 is a first-class, well-trodden
feature. The generated script embeds the site's private key directly — delete it from the
router's file list after importing.

## Files

```
qikehub                   CLI, single file (installed to /opt/qikehub, linked as /usr/local/sbin/qikehub)
/etc/qikehub/              hub.conf, peers.tsv, server.key/.pub, site-*.pub   (root 0700)
/etc/systemd/system/       qikehub-net.service, qikehub-wg.service, nftables.service.d/qikehub.conf
/etc/nftables.conf, /etc/sysctl.d/90-qikehub.conf
/var/lib/qikehub/out/      generated client/site bundles (delete after use)
```

## License

MIT — see `LICENSE`.
