# Pure Nix functions that produce nftables ruleset strings.
# No pkgs dependency — these only use lib for string manipulation.
#
# Two rulesets are generated:
#   1. Namespace ruleset (loaded inside the netns) — kill switch + DNS restriction
#   2. Host NAT ruleset (loaded on the host) — port forwarding into the namespace
{ lib }:
let
  inherit (lib)
    concatStringsSep
    concatMapStringsSep
    optionalString
    ;
  inherit (builtins) toString;

  # Expand a port definition into a list of protocols.
  # { port = 80; protocol = "both"; } → [ { port = 80; proto = "tcp"; } { port = 80; proto = "udp"; } ]
  expandProtocols = portDef: protocol:
    if protocol == "both" then
      [ "tcp" "udp" ]
    else
      [ protocol ];

  # Generate nftables port set syntax: "{ 80, 443, 8080 }"
  # from a list of port numbers.
  mkPortSet = ports:
    if builtins.length ports == 1 then
      toString (builtins.head ports)
    else
      "{ ${concatMapStringsSep ", " toString ports} }";

  # Group port definitions by protocol and collect port numbers.
  # Returns { tcp = [ 80 443 ]; udp = [ 51413 ]; }
  groupByProtocol = portDefs: portAccessor: protocolAccessor:
    let
      addPort = acc: def:
        let
          protos = expandProtocols def (protocolAccessor def);
          port = portAccessor def;
        in
        builtins.foldl' (a: proto:
          a // { ${proto} = (a.${proto} or []) ++ [ port ]; }
        ) acc protos;
    in
    builtins.foldl' addPort {} portDefs;

in rec {

  # ── Namespace ruleset ──────────────────────────────────────────────
  #
  # Loaded inside the network namespace. Implements:
  #   - Kill switch: OUTPUT policy drop, only wg interface allowed
  #   - DNS restriction: only VPN-provided DNS servers on 53/853
  #   - Input filtering: only mapped ports on veth, open ports on wg
  #
  # The DNS server IPs are only known at activation time (parsed from
  # the wg-quick config which may be a runtime secret), so we emit a
  # @DNS_RULES@ placeholder that the setup script fills in.

  mkNamespaceRuleset =
    { name              # namespace name (e.g., "wg")
    , vethName          # veth interface inside namespace (e.g., "veth-wg")
    , wgName            # wireguard interface name (e.g., "wg0")
    , portMappings      # [ { to; protocol; } ... ]
    , openVPNPorts      # [ { port; protocol; } ... ]
    , enableIPv6        # bool
    }:
    let
      # Group mapped ports (INPUT on veth) by protocol
      mappedByProto = groupByProtocol portMappings (p: p.to) (p: p.protocol);

      # Group VPN ports (INPUT on wg interface) by protocol
      vpnByProto = groupByProtocol openVPNPorts (p: p.port) (p: p.protocol);

      # Generate INPUT rules for a specific interface and protocol group
      mkInputRules = iface: byProto:
        concatStringsSep "\n" (
          lib.mapAttrsToList (proto: ports:
            "    iifname \"${iface}\" ${proto} dport ${mkPortSet ports} accept"
          ) byProto
        );

      vethInputRules = mkInputRules vethName mappedByProto;
      vpnInputRules = mkInputRules wgName vpnByProto;

    in ''
      table inet vpn-${name} {
        chain input {
          type filter hook input priority filter; policy drop;

          iif lo accept
          ct state invalid drop
          ct state established,related accept
      ${optionalString enableIPv6 ''
          # Neighbor discovery, router solicitation, etc.
          ip6 nexthdr ipv6-icmp accept
      ''}
          # Ports forwarded from host via DNAT (veth side)
      ${optionalString (vethInputRules != "") "    ${vethInputRules}"}

          # Ports open on the VPN interface (e.g., for seeding)
      ${optionalString (vpnInputRules != "") "    ${vpnInputRules}"}
        }

        chain output {
          type filter hook output priority filter; policy drop;

          oif lo accept
          ct state established,related accept

          # Intercept DNS traffic BEFORE the blanket wg accept.
          # This ensures dns-restrict can block DNS to non-VPN servers
          # even though the wg interface would otherwise carry it.
          udp dport 53 jump dns-restrict
          tcp dport 53 jump dns-restrict
          tcp dport 853 jump dns-restrict

          # All non-DNS traffic may exit through the WireGuard tunnel.
          # This is the kill switch: if the wg interface is down, nothing
          # matches and policy drop takes effect.
          oifname "${wgName}" accept

          # NOTE: No explicit veth outbound rule. Reply traffic to LAN
          # clients (e.g., Transmission RPC responses) is covered by
          # conntrack established,related above. If a future confined
          # service needs to *initiate* connections to the LAN, add:
          #   oifname "${vethName}" ip daddr { ... } accept
        }

        chain forward {
          type filter hook forward priority filter; policy drop;
        }

        chain dns-restrict {
          # Filled at activation time with VPN DNS server IPs.
          # Format:
          #   ip daddr <ipv4> accept
          #   ip6 daddr <ipv6> accept
          @DNS_RULES@

          # Everything else is dropped — no DNS to non-VPN servers.
          drop
        }
      }
    '';


  # ── Host NAT ruleset ───────────────────────────────────────────────
  #
  # Loaded on the host (default namespace). Handles DNAT of incoming
  # traffic to port-mapped services inside the VPN namespace.
  #
  # If there are no port mappings, this function returns null and the
  # setup script skips host NAT entirely.

  mkHostNatRuleset =
    { name              # namespace name
    , namespaceAddress  # IPv4 address inside namespace (DNAT target)
    , namespaceAddressIPv6
    , bridgeInterface   # bridge interface name (e.g., "wg-br")
    , portMappings      # [ { from; to; protocol; } ... ]
    , enableIPv6        # bool
    }:
    if portMappings == [] then
      ""
    else
      let
        # In an inet family table, we must use explicit family qualifiers
        # so that IPv4 DNAT rules only match IPv4 packets and vice versa.
        preroutingRules = concatMapStringsSep "\n" (mapping:
          let
            protos = expandProtocols mapping mapping.protocol;
          in
          concatMapStringsSep "\n" (proto: ''
            ${proto} dport ${toString mapping.from} dnat ip to ${namespaceAddress}:${toString mapping.to}''
            + optionalString enableIPv6 ''

            ${proto} dport ${toString mapping.from} dnat ip6 to [${namespaceAddressIPv6}]:${toString mapping.to}''
          ) protos
        ) portMappings;
      in ''
        table inet vpn-${name}-fwd {
          chain prerouting {
            type nat hook prerouting priority dstnat;
        ${preroutingRules}
          }

          chain postrouting {
            type nat hook postrouting priority srcnat;
            # Only masquerade traffic that was DNAT'd to the namespace.
            # This ensures reply packets have the bridge address as source,
            # so they route correctly back to the LAN client.
            oifname "${bridgeInterface}" ct status dnat masquerade
          }
        }
      '';
}
