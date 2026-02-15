{ lib, ... }:
let
  inherit (import ../lib/types.nix { inherit lib; }) ipAddress ipv4 ipv6;
  inherit (lib) mkEnableOption mkOption;
  inherit (lib.types)
    listOf
    submodule
    path
    port
    enum
    ;
in
{
  options = {
    enable = mkEnableOption "vpn netns" // {
      description = ''
        Whether to enable the VPN namespace.

        Creates a network namespace with a WireGuard tunnel, connected to
        the host via a veth pair and linux bridge. Traffic inside the
        namespace can only exit through the WireGuard interface (kill
        switch enforced by nftables). DNS is restricted to VPN-provided
        servers.
      '';
    };

    wireguardConfigFile = mkOption {
      type = path;
      default = null;
      example = "/run/secrets/wg0.conf";
      description = ''
        Path to a wg-quick configuration file.

        Parsed at activation time (not build time) by a safe parser
        that never uses eval/source. The file may contain secrets
        and is not copied into the Nix store.

        Must contain at minimum: PrivateKey, Address, DNS in
        [Interface], and at least one [Peer] with PublicKey.
      '';
    };

    accessibleFrom = mkOption {
      type = listOf ipAddress;
      default = [ ];
      description = ''
        Subnets and addresses that can reach the namespace through
        the veth/bridge, and that the namespace can route back to.

        Used for LAN access to services running inside the namespace
        (e.g., Transmission's web UI). Routes are added inside the
        namespace so reply traffic reaches these subnets via the bridge
        rather than being sent through the WireGuard tunnel.
      '';
      example = [
        "10.0.2.0/24"
        "192.168.1.27"
        "fd25:9ab6:6133::/64"
      ];
    };

    namespaceAddress = mkOption {
      type = ipv4;
      default = "192.168.15.1";
      description = ''
        IPv4 address of the veth interface inside the VPN namespace.

        This is the address used to reach services in the namespace
        from the host or LAN (via port mappings or direct access
        through the bridge).
      '';
    };

    namespaceAddressIPv6 = mkOption {
      type = ipv6;
      default = "fd93:9701:1d00::2";
      description = ''
        IPv6 address of the veth interface inside the VPN namespace.
      '';
    };

    bridgeAddress = mkOption {
      type = ipv4;
      default = "192.168.15.5";
      description = ''
        IPv4 address of the linux bridge on the host (default namespace).

        The bridge connects the host to the VPN namespace via the veth
        pair. This address serves as the gateway for routes inside the
        namespace back to accessibleFrom subnets.
      '';
    };

    bridgeAddressIPv6 = mkOption {
      type = ipv6;
      default = "fd93:9701:1d00::1";
      description = ''
        IPv6 address of the linux bridge on the host (default namespace).
      '';
    };

    openVPNPorts = mkOption {
      type = listOf (submodule {
        options = {
          port = mkOption {
            type = port;
            description = "The port to open on the WireGuard interface.";
          };
          protocol = mkOption {
            default = "tcp";
            example = "both";
            type = enum [
              "tcp"
              "udp"
              "both"
            ];
            description = "The transport layer protocol.";
          };
        };
      });
      default = [ ];
      description = ''
        Ports accessible through the VPN interface (e.g., for
        BitTorrent seeding). These are opened in the namespace's
        nftables INPUT chain on the WireGuard interface.
      '';
    };

    portMappings = mkOption {
      type = listOf (submodule {
        options = {
          from = mkOption {
            example = 80;
            type = port;
            description = "Port on the host (default namespace).";
          };
          to = mkOption {
            example = 443;
            type = port;
            description = "Port inside the VPN namespace.";
          };
          protocol = mkOption {
            default = "tcp";
            example = "both";
            type = enum [
              "tcp"
              "udp"
              "both"
            ];
            description = "The transport layer protocol.";
          };
        };
      });
      default = [ ];
      description = ''
        Port mappings from the host into the VPN namespace.

        Traffic arriving at the host on the 'from' port is DNAT'd to
        the namespace's veth address on the 'to' port. The 'to' ports
        are automatically opened in the namespace's INPUT chain.

        Neither 'from' nor 'to' ports should be otherwise in use on
        the host — they are fully routed to the namespace.
      '';
      example = [
        {
          from = 9091;
          to = 9091;
          protocol = "tcp";
        }
      ];
    };
  };
}
