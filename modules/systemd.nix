{ lib, ... }:
let
  inherit (lib) mkOption mkIf mkDefault;
  inherit (lib.types)
    attrsOf
    submodule
    bool
    str
    ;
in
{
  options.systemd.services = mkOption {
    type = attrsOf (
      submodule (
        { config, ... }:
        {
          options.vpnConfinement = {
            enable = mkOption {
              type = bool;
              default = false;
              description = ''
                Whether to confine this systemd service inside a VPN
                network namespace. When enabled, all traffic from the
                service is routed through the WireGuard tunnel, DNS is
                restricted to VPN-provided servers, and systemd
                sandboxing is applied.
              '';
            };
            vpnNamespace = mkOption {
              type = str;
              default = "";
              example = "wg";
              description = ''
                Name of the VPN network namespace to use. Must match
                a name defined in vpnNamespaces.<name>.
              '';
            };
          };

          config =
            let
              vpn = config.vpnConfinement.vpnNamespace;
            in
            mkIf config.vpnConfinement.enable {
              # ── Service dependencies ──────────────────────────────
              # The confined service must start after the namespace is
              # up, and must stop if the namespace service stops.
              bindsTo = [ "${vpn}.service" ];
              after = [ "${vpn}.service" ];

              serviceConfig = {
                # ── Network isolation ─────────────────────────────
                NetworkNamespacePath = "/run/netns/${vpn}";

                BindReadOnlyPaths = [
                  "/etc/netns/${vpn}/resolv.conf:/etc/resolv.conf:norbind"
                ];

                InaccessiblePaths = [
                  "/run/nscd"
                  "/run/resolvconf"
                ];

                # ── Systemd hardening ─────────────────────────────
                # Applied via mkDefault so users can override individual
                # settings with a plain assignment in their NixOS config.
                #
                # These don't interfere with networking (that's handled
                # by the namespace) but reduce blast radius if the
                # confined service is compromised.

                ProtectSystem = mkDefault "strict";
                ProtectHome = mkDefault true;
                PrivateTmp = mkDefault true;
                PrivateDevices = mkDefault true;
                ProtectKernelTunables = mkDefault true;
                ProtectKernelModules = mkDefault true;
                ProtectControlGroups = mkDefault true;
                NoNewPrivileges = mkDefault true;
                RestrictSUIDSGID = mkDefault true;
              };
            };
        }
      )
    );
  };
}
