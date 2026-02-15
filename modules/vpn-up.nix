# Builds the ExecStart script as a writeShellApplication.
#
# This script:
#   1. Parses the wg-quick config file safely
#   2. Creates the network namespace
#   3. Creates and configures the WireGuard interface (container pattern)
#   4. Sets up the veth pair and bridge for LAN connectivity
#   5. Applies nftables firewall inside the namespace (kill switch + DNS)
#   6. Applies host-side NAT for port forwarding (if any)
#   7. Writes DNS resolv.conf for the namespace
{
  pkgs,
  lib,
  parseWgQuick,    # the parse-wg-quick package
  optionalIPv6,    # string → string (identity if IPv6 enabled, "" if not)
}:
netnsName: def:
let
  inherit (lib) concatMapStringsSep optionalString;
  inherit (import ../lib/utils.nix { inherit lib; }) isValidIPv4;

  nftablesLib = import ./nftables.nix { inherit lib; };

  # IPv6 is enabled at the system level — optionalIPv6 returns ""
  # when disabled, non-empty when enabled.
  enableIPv6 = optionalIPv6 "x" != "";

  # Generate the namespace ruleset template (with @DNS_RULES@ placeholder)
  nsRuleset = nftablesLib.mkNamespaceRuleset {
    name = netnsName;
    vethName = "veth-${netnsName}";
    wgName = "${netnsName}0";
    portMappings = def.portMappings;
    openVPNPorts = def.openVPNPorts;
    inherit enableIPv6;
  };

  # Generate the host NAT ruleset (null if no port mappings)
  hostRuleset = nftablesLib.mkHostNatRuleset {
    name = netnsName;
    namespaceAddress = def.namespaceAddress;
    namespaceAddressIPv6 = def.namespaceAddressIPv6;
    bridgeInterface = "${netnsName}-br";
    portMappings = def.portMappings;
    inherit enableIPv6;
  };

  hasPortMappings = def.portMappings != [];

in
pkgs.writeShellApplication {
  name = "${netnsName}-up";
  runtimeInputs = with pkgs; [
    iproute2
    wireguard-tools
    nftables
    unixtools.ping
    parseWgQuick
  ];
  text = ''
    PARSED_DIR=$(mktemp -d "/tmp/wg-parsed.XXXXXX")
    trap 'rm -rf "$PARSED_DIR"' EXIT

    # ── Phase 1: Parse the wg-quick config ────────────────────────────
    parse-wg-quick ${def.wireguardConfigFile} "$PARSED_DIR"

    # ── Phase 2: Create namespace ─────────────────────────────────────
    ip netns add ${netnsName}
    ip netns exec ${netnsName} ip link set lo up

    # ── Phase 3: Create WireGuard interface (container pattern) ───────
    #
    # The interface is created in the init namespace (where physical
    # interfaces and internet access live). Its UDP socket stays here.
    # Then it is moved into the confined namespace, so processes there
    # can only send traffic through the encrypted tunnel.
    ip link add ${netnsName}0 type wireguard
    wg setconf ${netnsName}0 "$PARSED_DIR/wg.conf"
    ip link set ${netnsName}0 netns ${netnsName}

    # Assign addresses from the parsed config
    while IFS= read -r addr; do
      ip -n ${netnsName} address add "$addr" dev ${netnsName}0
    done < "$PARSED_DIR/addresses"

    # Apply MTU if specified in the config
    if [[ -f "$PARSED_DIR/mtu" ]]; then
      mtu=$(cat "$PARSED_DIR/mtu")
      ip -n ${netnsName} link set ${netnsName}0 mtu "$mtu"
    fi

    ip -n ${netnsName} link set ${netnsName}0 up

    # ── Phase 4: Wait for endpoint reachability ───────────────────────
    if [[ -s "$PARSED_DIR/endpoints" ]]; then
      while IFS= read -r endpoint; do
        # Extract IP/hostname — strip the port.
        # Handles both IPv4 (1.2.3.4:51820) and IPv6 ([::1]:51820) formats.
        if [[ "$endpoint" =~ ^\[?([^]]+)\]?:[0-9]+$ ]]; then
          endpoint_ip="''${BASH_REMATCH[1]}"
        else
          echo "warning: could not parse endpoint '$endpoint', skipping reachability check" >&2
          continue
        fi

        attempt=1
        max_retries=5
        success=false
        echo -n "Waiting for endpoint '$endpoint_ip' to be reachable..."
        while [[ $attempt -le $max_retries ]]; do
          if ping -c 1 -W 2 "$endpoint_ip" > /dev/null 2>&1; then
            success=true
            break
          fi
          sleep 1
          attempt=$((attempt + 1))
        done

        if ! $success; then
          echo ""
          echo "error: failed to reach '$endpoint_ip' after $max_retries attempts" >&2
          exit 1
        else
          echo " ok"
        fi
      done < "$PARSED_DIR/endpoints"
    fi

    # ── Phase 5: Create bridge and veth pair ──────────────────────────
    ip link add ${netnsName}-br type bridge
    ip addr add ${def.bridgeAddress}/24 dev ${netnsName}-br
    ${optionalIPv6 ''
      ip addr add ${def.bridgeAddressIPv6}/64 dev ${netnsName}-br
    ''}
    ip link set dev ${netnsName}-br up

    ip link add veth-${netnsName}-br type veth peer \
      name veth-${netnsName} netns ${netnsName}
    ip link set veth-${netnsName}-br master ${netnsName}-br
    ip link set dev veth-${netnsName}-br up

    ip -n ${netnsName} addr add ${def.namespaceAddress}/24 \
      dev veth-${netnsName}
    ${optionalIPv6 ''
      ip -n ${netnsName} addr add ${def.namespaceAddressIPv6}/64 \
        dev veth-${netnsName}
    ''}
    ip -n ${netnsName} link set dev veth-${netnsName} up

    # ── Phase 6: Add routes ───────────────────────────────────────────
    ip -n ${netnsName} route add default dev ${netnsName}0
    ${optionalIPv6 ''
      ip -6 -n ${netnsName} route add default dev ${netnsName}0
    ''}

    # Routes for accessibleFrom subnets — these go via the bridge so
    # reply traffic reaches the LAN instead of being tunneled.
    ${concatMapStringsSep "\n" (x:
      if isValidIPv4 x then
        "ip -n ${netnsName} route add ${x} via ${def.bridgeAddress}"
      else
        optionalIPv6
          "ip -n ${netnsName} route add ${x} via ${def.bridgeAddressIPv6}"
    ) def.accessibleFrom}

    # ── Phase 7: Apply nftables inside namespace ──────────────────────
    #
    # Build the DNS restriction rules from parsed DNS servers.
    DNS_RULES=""
    while IFS= read -r ns; do
      if [[ "$ns" == *"."* ]]; then
        DNS_RULES+="    ip daddr $ns udp dport 53 accept"$'\n'
        DNS_RULES+="    ip daddr $ns tcp dport 53 accept"$'\n'
        DNS_RULES+="    ip daddr $ns tcp dport 853 accept"$'\n'
      ${optionalIPv6 ''
        elif [[ "$ns" == *":"* ]]; then
          DNS_RULES+="    ip6 daddr $ns udp dport 53 accept"$'\n'
          DNS_RULES+="    ip6 daddr $ns tcp dport 53 accept"$'\n'
          DNS_RULES+="    ip6 daddr $ns tcp dport 853 accept"$'\n'
      ''}
      fi
    done < "$PARSED_DIR/dns"

    # Substitute the placeholder and load the ruleset
    NS_RULESET_FILE=$(mktemp "/tmp/nft-ns.XXXXXX")
    cat > "$NS_RULESET_FILE" << 'NFTABLES_EOF'
    ${nsRuleset}
    NFTABLES_EOF

    # Replace the placeholder with actual DNS rules
    # Use a temp file approach since sed with multi-line variables is fragile
    FILLED_RULESET=$(mktemp "/tmp/nft-ns-filled.XXXXXX")
    while IFS= read -r line; do
      if [[ "$line" == *"@DNS_RULES@"* ]]; then
        printf '%s' "$DNS_RULES"
      else
        printf '%s\n' "$line"
      fi
    done < "$NS_RULESET_FILE" > "$FILLED_RULESET"

    ip netns exec ${netnsName} nft -f "$FILLED_RULESET"
    rm -f "$NS_RULESET_FILE" "$FILLED_RULESET"

    # ── Phase 8: Apply host-side NAT (if port mappings exist) ─────────
    ${optionalString hasPortMappings ''
      HOST_RULESET_FILE=$(mktemp "/tmp/nft-host.XXXXXX")
      cat > "$HOST_RULESET_FILE" << 'HOST_NFT_EOF'
      ${hostRuleset}
      HOST_NFT_EOF
      nft -f "$HOST_RULESET_FILE"
      rm -f "$HOST_RULESET_FILE"
    ''}

    # ── Phase 9: Write DNS resolv.conf ────────────────────────────────
    rm -rf /etc/netns/${netnsName}
    mkdir -p /etc/netns/${netnsName}
    while IFS= read -r ns; do
      echo "nameserver $ns" >> /etc/netns/${netnsName}/resolv.conf
    done < "$PARSED_DIR/dns"

    echo "${netnsName}: namespace setup complete"
  '';
}
