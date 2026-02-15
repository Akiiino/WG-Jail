{
  name = "VPN-Confinement Tests";

  nodes =
    let
      # ── Shared base config ──────────────────────────────────────────
      #
      # Dummy WireGuard config with placeholder keys. The tunnel won't
      # actually connect (no real peer), but the namespace setup, firewall
      # rules, interfaces, and teardown are all fully exercised.
      base = {
        environment.etc =
          let
            config = ''
              [Interface]
              PrivateKey = 8PZQ8felOfsPGDaAPdHaJlkf0hcCn6JGhU1DJq5Ts3M=
              Address = 10.100.0.2/24
              DNS = 1.1.1.1

              [Peer]
              PublicKey = ObYLOQ9jBDhE2a/Jxgzg3f+Navp0rXjkctKCelb0xEI=
              AllowedIPs = 0.0.0.0/0
              Endpoint = 127.0.0.1:51820
            '';
          in
          {
            "wireguard/wg0.conf".text = config;
          };
      };

      # ── Standard namespace config ───────────────────────────────────
      basicNetns = {
        vpnNamespaces.wg = {
          enable = true;
          wireguardConfigFile = "/etc/wireguard/wg0.conf";
          accessibleFrom = [
            "192.168.0.0/24"
            "10.0.0.0/8"
            "127.0.0.1"
          ];
          portMappings = [
            {
              from = 9091;
              to = 9091;
            }
          ];
          openVPNPorts = [
            {
              port = 60729;
              protocol = "both";
            }
          ];
        };
      };

      createNode = configs:
        { pkgs, lib, ... }:
        {
          imports = [ (import ../modules/vpn-netns.nix) ];
          config = lib.mkMerge (configs ++ [
            base
            # Ensure nft is in PATH for test assertions
            { environment.systemPackages = [ pkgs.nftables ]; }
          ]);
        };

    in
    {
      # ── Test nodes ────────────────────────────────────────────────────

      # Basic: verify interfaces, link states, nftables loaded
      machine_basic = createNode [ basicNetns ];

      # systemd-networkd backend instead of dhcpcd
      machine_networkd = createNode [
        basicNetns
        {
          networking.useNetworkd = true;
          systemd.network.enable = true;
          networking.useDHCP = false;
          networking.dhcpcd.enable = false;
        }
      ];

      # Kill switch: verify traffic is dropped when wg interface goes down
      machine_kill_switch = createNode [ basicNetns ];

      # DNS confinement: verify nftables rules restrict DNS
      machine_dns = createNode [ basicNetns ];

      # Port forwarding: verify host NAT rules exist
      machine_port_forward = createNode [ basicNetns ];

      # Teardown: verify clean removal of all resources
      machine_teardown = createNode [ basicNetns ];

      # systemd-resolved compatibility
      machine_resolved = createNode [
        basicNetns
        {
          services.resolved.enable = true;
          services.prowlarr.enable = true;

          systemd.services.prowlarr = {
            vpnConfinement.enable = true;
            vpnConfinement.vpnNamespace = "wg";
          };
        }
      ];

      # IPv6 disabled
      machine_ipv6_disabled = createNode [
        basicNetns
        {
          networking.enableIPv6 = false;
        }
      ];

      # Maximum name length (7 chars)
      machine_max_name = createNode [
        {
          vpnNamespaces.vpnname = {
            enable = true;
            wireguardConfigFile = "/etc/wireguard/wg0.conf";
          };
        }
      ];

      # Name containing a dash
      machine_dash_name = createNode [
        {
          vpnNamespaces.vpn-nam = {
            enable = true;
            wireguardConfigFile = "/etc/wireguard/wg0.conf";
          };
        }
      ];

      # No namespaces defined — module should be a no-op
      machine_no_namespaces = createNode [ { } ];

      # Multiple independent namespaces
      machine_multi_ns = createNode [
        basicNetns
        {
          environment.etc."wireguard/wg1.conf".text = ''
            [Interface]
            PrivateKey = UF0rr4cXHYKqm2TpWjICwDTkYZ0lgQy2bS2NVvzEZF4=
            Address = 10.200.0.2/24
            DNS = 10.200.0.1

            [Peer]
            PublicKey = bJG8THXP1FrkMaV2eDwA0bIBmZqAM29rMCYPGXPcSzs=
            AllowedIPs = 0.0.0.0/0
            Endpoint = 127.0.0.1:51821
          '';

          vpnNamespaces.wg2 = {
            enable = true;
            wireguardConfigFile = "/etc/wireguard/wg1.conf";
            namespaceAddress = "192.168.16.1";
            bridgeAddress = "192.168.16.5";
            namespaceAddressIPv6 = "fd93:9701:1d01::2";
            bridgeAddressIPv6 = "fd93:9701:1d01::1";
          };
        }
      ];
    };

  testScript = ''
    # ── machine_basic: interfaces and link states ─────────────────────

    machine_basic.wait_for_unit("wg.service")

    machine_basic.succeed(
      '[ "$(cat /sys/class/net/wg-br/operstate)" = "up" ]'
    )
    machine_basic.succeed(
      '[ "$(cat /sys/class/net/veth-wg-br/operstate)" = "up" ]'
    )
    machine_basic.succeed(
      '[ "$(ip netns exec wg cat /sys/class/net/veth-wg/operstate)" = "up" ]'
    )

    # Verify nftables ruleset is loaded inside the namespace
    machine_basic.succeed(
      "ip netns exec wg nft list table inet vpn-wg"
    )

    # ── machine_networkd: same checks with networkd backend ───────────

    machine_networkd.wait_for_unit("wg.service")

    machine_networkd.succeed(
      '[ "$(cat /sys/class/net/wg-br/operstate)" = "up" ]'
    )
    machine_networkd.succeed(
      '[ "$(cat /sys/class/net/veth-wg-br/operstate)" = "up" ]'
    )
    machine_networkd.succeed(
      '[ "$(ip netns exec wg cat /sys/class/net/veth-wg/operstate)" = "up" ]'
    )

    # ── machine_kill_switch: traffic dropped when wg is down ──────────
    #
    # This is the critical test the original module lacked.

    machine_kill_switch.wait_for_unit("wg.service")

    # Bring down the wg interface inside the namespace
    machine_kill_switch.succeed(
      "ip -n wg link set wg0 down"
    )

    # Attempt to ping an external IP from inside the namespace.
    # This MUST fail — with wg0 down, the default route is gone and the
    # nftables OUTPUT policy drop catches anything that slips through.
    machine_kill_switch.fail(
      "ip netns exec wg ping -c 1 -W 2 8.8.8.8"
    )

    # Verify that new outbound connections to the bridge are also blocked
    # by nftables. The veth and route to 192.168.15.0/24 still exist, but
    # the OUTPUT chain has no rule allowing new traffic on the veth —
    # only conntrack established,related is permitted. This tests the
    # nftables rules specifically (not just routing).
    machine_kill_switch.fail(
      "ip netns exec wg ping -c 1 -W 2 192.168.15.5"
    )

    # ── machine_dns: nftables DNS restriction rules ───────────────────

    machine_dns.wait_for_unit("wg.service")

    # Verify the dns-restrict chain exists and has the VPN DNS server
    machine_dns.succeed(
      "ip netns exec wg nft list chain inet vpn-wg dns-restrict | grep -q '1.1.1.1'"
    )

    # Verify the chain ends with a drop
    machine_dns.succeed(
      "ip netns exec wg nft list chain inet vpn-wg dns-restrict | grep -q 'drop'"
    )

    # Verify DNS port interception rules exist in the output chain
    machine_dns.succeed(
      "ip netns exec wg nft list chain inet vpn-wg output | grep -q 'udp dport 53 jump dns-restrict'"
    )
    machine_dns.succeed(
      "ip netns exec wg nft list chain inet vpn-wg output | grep -q 'tcp dport 853 jump dns-restrict'"
    )

    # Verify resolv.conf was written correctly
    machine_dns.succeed(
      "ip netns exec wg cat /etc/resolv.conf | grep -q 'nameserver 1.1.1.1'"
    )

    # ── machine_port_forward: host NAT rules ──────────────────────────

    machine_port_forward.wait_for_unit("wg.service")

    # The host NAT table should exist
    machine_port_forward.succeed(
      "nft list table inet vpn-wg-fwd"
    )

    # Should have DNAT rule for port 9091
    machine_port_forward.succeed(
      "nft list chain inet vpn-wg-fwd prerouting | grep -q '9091'"
    )

    # Should have masquerade rule scoped to DNAT'd traffic
    machine_port_forward.succeed(
      "nft list chain inet vpn-wg-fwd postrouting | grep -q 'masquerade'"
    )

    # ── machine_teardown: clean removal ───────────────────────────────

    machine_teardown.wait_for_unit("wg.service")

    # Stop the service
    machine_teardown.succeed("systemctl stop wg.service")

    # No stale bridge
    machine_teardown.fail(
      "ip link show wg-br 2>/dev/null"
    )

    # No stale namespace
    machine_teardown.fail(
      "ip netns list | grep -q '^wg '"
    )
    machine_teardown.fail(
      "ip netns list | grep -q '^wg$'"
    )

    # No stale host NAT table
    machine_teardown.fail(
      "nft list table inet vpn-wg-fwd 2>/dev/null"
    )

    # No stale DNS config
    machine_teardown.fail(
      "test -d /etc/netns/wg"
    )

    # ── machine_resolved: systemd-resolved compatibility ──────────────

    machine_resolved.wait_for_unit("wg.service")
    machine_resolved.wait_for_unit("prowlarr.service")

    machine_resolved.succeed(
      '[ "$(cat /sys/class/net/wg-br/operstate)" = "up" ]'
    )

    # ── machine_ipv6_disabled: no IPv6 rules ──────────────────────────

    machine_ipv6_disabled.wait_for_unit("wg.service")

    # nftables ruleset should NOT contain any ip6 rules
    machine_ipv6_disabled.succeed(
      "! ip netns exec wg nft list table inet vpn-wg | grep -q 'ip6'"
    )

    # ── machine_max_name: 7-character name ────────────────────────────

    machine_max_name.wait_for_unit("vpnname.service")

    machine_max_name.succeed(
      '[ "$(cat /sys/class/net/vpnname-br/operstate)" = "up" ]'
    )
    machine_max_name.succeed(
      '[ "$(cat /sys/class/net/veth-vpnname-br/operstate)" = "up" ]'
    )
    machine_max_name.succeed(
      '[ "$(ip netns exec vpnname cat /sys/class/net/veth-vpnname/operstate)" = "up" ]'
    )

    # ── machine_dash_name: name with dashes ───────────────────────────

    machine_dash_name.wait_for_unit("vpn-nam.service")

    machine_dash_name.succeed(
      '[ "$(cat /sys/class/net/vpn-nam-br/operstate)" = "up" ]'
    )

    # ── machine_no_namespaces: module is a no-op ──────────────────────
    #
    # Just verify the machine boots successfully.
    machine_no_namespaces.wait_for_unit("multi-user.target")

    # ── machine_multi_ns: two independent namespaces ──────────────────

    machine_multi_ns.wait_for_unit("wg.service")
    machine_multi_ns.wait_for_unit("wg2.service")

    # Both bridges should be up
    machine_multi_ns.succeed(
      '[ "$(cat /sys/class/net/wg-br/operstate)" = "up" ]'
    )
    machine_multi_ns.succeed(
      '[ "$(cat /sys/class/net/wg2-br/operstate)" = "up" ]'
    )

    # Both namespaces should have their own nftables rulesets
    machine_multi_ns.succeed(
      "ip netns exec wg nft list table inet vpn-wg"
    )
    machine_multi_ns.succeed(
      "ip netns exec wg2 nft list table inet vpn-wg2"
    )

    # Namespaces should have different addresses
    machine_multi_ns.succeed(
      "ip netns exec wg ip addr show veth-wg | grep -q '192.168.15.1'"
    )
    machine_multi_ns.succeed(
      "ip netns exec wg2 ip addr show veth-wg2 | grep -q '192.168.16.1'"
    )
  '';
}
