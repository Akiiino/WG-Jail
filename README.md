# VPN-Confinement

A NixOS module that confines systemd services to a WireGuard VPN namespace. Traffic from confined services can only exit through the WireGuard tunnel. If the tunnel goes down, traffic is **dropped**, not rerouted.

## Features

- **Kill switch** — nftables `policy drop` on OUTPUT; only the WireGuard interface is allowed. No traffic escapes if the tunnel is down.
- **DNS confinement** — DNS queries are restricted to VPN-provided servers on UDP/53, TCP/53, and TCP/853 (DoT). Queries to other resolvers are dropped.
- **nftables** — atomic rulesets loaded per namespace. No iptables string concatenation. Clean teardown via `nft delete table`.
- **Safe config parsing** — wg-quick `.conf` files are parsed by a dedicated script that never uses `eval`, `source`, or dynamic code execution.
- **Systemd hardening** — confined services get `ProtectSystem=strict`, `NoNewPrivileges`, `PrivateTmp`, and more by default.
- **Loud failures** — teardown scripts do not silence errors. If cleanup fails, the service is marked failed.

## Installation

### Nix Flake

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    vpn-confinement.url = "github:your-user/VPN-Confinement";
  };

  outputs = { self, nixpkgs, vpn-confinement, ... }:
  {
    nixosConfigurations.hostname = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        vpn-confinement.nixosModules.default
      ];
    };
  };
}
```

## Usage

### Define a VPN namespace

```nix
vpnNamespaces.wg = {
  enable = true;

  # Path to a wg-quick config file (parsed safely at activation time).
  # Must contain PrivateKey, Address, DNS, and at least one Peer.
  wireguardConfigFile = "/run/secrets/wg0.conf";

  # Subnets that can reach the namespace (e.g., your LAN).
  # Reply traffic to these subnets goes via the bridge, not the tunnel.
  accessibleFrom = [ "192.168.0.0/24" ];

  # Forward host port 9091 to namespace port 9091 (Transmission WebUI).
  portMappings = [
    { from = 9091; to = 9091; protocol = "tcp"; }
  ];

  # Open port on the WireGuard interface (e.g., for BitTorrent seeding).
  openVPNPorts = [
    { port = 51413; protocol = "both"; }
  ];

  # Optional: customize bridge/namespace addresses
  # namespaceAddress = "192.168.15.1";   # default
  # bridgeAddress = "192.168.15.5";      # default
};
```

### Confine a service

```nix
systemd.services.transmission.vpnConfinement = {
  enable = true;
  vpnNamespace = "wg";
};
```

### Complete example (Transmission + ProtonVPN)

```nix
# configuration.nix
{ pkgs, lib, config, ... }:
{
  vpnNamespaces.wg = {
    enable = true;
    wireguardConfigFile = "/run/secrets/protonvpn-wg.conf";
    accessibleFrom = [ "192.168.0.0/24" ];
    portMappings = [
      { from = 9091; to = 9091; }
    ];
    openVPNPorts = [
      { port = 51413; protocol = "both"; }
    ];
  };

  systemd.services.transmission.vpnConfinement = {
    enable = true;
    vpnNamespace = "wg";
  };

  services.transmission = {
    enable = true;
    settings = {
      rpc-bind-address = "192.168.15.1";
      rpc-whitelist = "192.168.0.*";
    };
  };
}
```

Access the Transmission WebUI from your LAN at `http://192.168.15.1:9091` (the namespace address), or from the host at the same address.

## How It Works

```
┌── Host (default namespace) ───────────────────────────┐
│                                                        │
│  Physical NIC ←→ internet                              │
│       ↕                                                │
│  wg0 socket (encrypted UDP, lives in host)             │
│       ↕                                                │
│  ┌── Bridge (wg-br) ──┐                               │
│  │  192.168.15.5       │ ← port 9091 DNAT'd here      │
│  │  veth-wg-br ────────┼──────────┐                   │
│  └─────────────────────┘          │ veth pair          │
│                                    │                    │
├── VPN namespace (wg) ──────────────┼────────────────────┤
│                                    │                    │
│  veth-wg (192.168.15.1) ──────────┘                   │
│       ↕                                                │
│  wg0 interface (decrypted)                              │
│       ↕                                                │
│  ┌── nftables (kill switch) ──────────────────────┐   │
│  │  OUTPUT: policy drop                            │   │
│  │    → dns-restrict chain (VPN DNS only)          │   │
│  │    → oifname "wg0" accept                       │   │
│  │    → (everything else dropped)                   │   │
│  │  INPUT: policy drop                             │   │
│  │    → ct state established,related accept         │   │
│  │    → veth: port 9091 accept                      │   │
│  │    → wg0: port 51413 accept                      │   │
│  └─────────────────────────────────────────────────┘   │
│                                                        │
│  Transmission (confined service)                        │
│    - NetworkNamespacePath=/run/netns/wg                 │
│    - ProtectSystem=strict, NoNewPrivileges, ...         │
└────────────────────────────────────────────────────────┘
```

## Namespace name limit

Namespace names are limited to **7 characters**. This is because the longest derived interface name is `veth-<name>-br`, and the Linux kernel limits interface names to 15 characters (`IFNAMSIZ`).

## Systemd hardening

Confined services automatically get these systemd security settings (via `mkDefault`, so you can override any of them):

- `ProtectSystem = "strict"` — read-only `/usr`, `/boot`, `/efi`
- `ProtectHome = true` — hide `/home`, `/root`, `/run/user`
- `PrivateTmp = true` — isolated `/tmp`
- `PrivateDevices = true` — minimal `/dev`
- `ProtectKernelTunables = true` — read-only `/proc/sys`, `/sys`
- `ProtectKernelModules = true` — prevent module loading
- `ProtectControlGroups = true` — read-only cgroup tree
- `NoNewPrivileges = true`
- `RestrictSUIDSGID = true`

To override a specific setting for a service:

```nix
systemd.services.myservice.serviceConfig.ProtectHome = false;
```

## DNS leak prevention

DNS is restricted at two levels:

1. **resolv.conf** — the namespace sees only VPN-provided nameservers
2. **nftables** — a `dns-restrict` chain drops DNS traffic (UDP/53, TCP/53, TCP/853) to any server not in the VPN's DNS list

**Note on DoH:** DNS-over-HTTPS (port 443) cannot be blocked without also blocking all HTTPS traffic. Since all traffic goes through the WireGuard tunnel anyway, a DoH query to a third-party resolver is still tunneled — it doesn't bypass the VPN. The risk is the query going to a non-VPN server (privacy leak), not that it bypasses the tunnel (routing leak).

## Testing

```bash
nix flake check -L
```

This runs both the parser unit tests and the NixOS VM integration tests.

## Options reference

See all options and their descriptions in [modules/options.nix](modules/options.nix).

## License

MIT
