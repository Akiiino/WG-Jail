# Builds the ExecStopPost script for namespace teardown.
#
# Cleans up all resources created by vpn-up. Errors are NOT silenced —
# if cleanup fails, the service is marked failed so the operator knows.
#
# Each step is guarded by an existence check so partial teardown
# (e.g., after a failed setup) doesn't produce spurious errors.
{
  pkgs,
  hasPortMappings,  # bool — whether host NAT table was created
}:
netnsName:
pkgs.writeShellApplication {
  name = "${netnsName}-down";
  runtimeInputs = with pkgs; [
    iproute2
    nftables
  ];
  text = ''
    # ── Step 1: Remove host NAT table ─────────────────────────────────
    ${if hasPortMappings then ''
      if nft list table inet vpn-${netnsName}-fwd > /dev/null 2>&1; then
        nft delete table inet vpn-${netnsName}-fwd
        echo "${netnsName}: removed host NAT table"
      fi
    '' else ''
      # No port mappings configured — no host NAT table to remove.
    ''}

    # ── Step 2: Delete the network namespace ──────────────────────────
    #
    # Deleting the namespace automatically destroys all interfaces
    # inside it, including the veth peer (veth-${netnsName}). The host
    # end (veth-${netnsName}-br) is also destroyed since veth pairs are
    # removed when either end is deleted.
    if ip netns list | grep -q "^${netnsName} \|^${netnsName}$"; then
      # Remove nftables inside the namespace before deleting it.
      # This is belt-and-suspenders — the namespace deletion would
      # clean up anyway, but being explicit is cheap.
      if ip netns exec ${netnsName} nft list table inet vpn-${netnsName} > /dev/null 2>&1; then
        ip netns exec ${netnsName} nft delete table inet vpn-${netnsName}
      fi

      ip netns del ${netnsName}
      echo "${netnsName}: removed network namespace"
    fi

    # ── Step 3: Delete the bridge ─────────────────────────────────────
    #
    # The bridge is on the host (default namespace) and is NOT
    # automatically removed when the netns is deleted.
    if ip link show ${netnsName}-br > /dev/null 2>&1; then
      ip link del ${netnsName}-br
      echo "${netnsName}: removed bridge"
    fi

    # ── Step 4: Clean up DNS ──────────────────────────────────────────
    rm -rf /etc/netns/${netnsName}

    echo "${netnsName}: teardown complete"
  '';
}
