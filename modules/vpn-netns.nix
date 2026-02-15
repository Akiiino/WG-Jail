{
  pkgs,
  lib,
  config,
  ...
}:
let
  inherit (lib)
    mkIf
    mkOption
    nameValuePair
    mapAttrs'
    optionalString
    ;
  inherit (lib.types) attrsOf submodule;

  isIPv6Enabled = config.networking.enableIPv6;
  optionalIPv6 = x: optionalString isIPv6Enabled x;

  parseWgQuickPkg =
    (import ../pkgs/parse-wg-quick { inherit pkgs lib; }).parseWgQuick;

  namespaceToService =
    name: def:
    assert
      builtins.stringLength name < 8
      || throw ''
        vpnNamespaces.${name}: name "${name}" is ${toString (builtins.stringLength name)} characters.
        Maximum is 7 characters. This limit exists because the longest derived
        interface name is "veth-<name>-br" (8 + name length), and the Linux
        kernel limits interface names to 15 characters (IFNAMSIZ).
      '';
    rec {
      description = "${name} VPN network namespace";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = with serviceConfig; [
        ExecStart
        ExecStopPost
      ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;

        ExecStart =
          let
            vpnUp = import ./vpn-up.nix {
              inherit pkgs lib;
              parseWgQuick = parseWgQuickPkg;
              inherit optionalIPv6;
            };
          in
          "${vpnUp name def}/bin/${name}-up";

        ExecStopPost =
          let
            vpnDown = import ./vpn-down.nix {
              inherit pkgs;
              hasPortMappings = def.portMappings != [];
            };
          in
          "${vpnDown name}/bin/${name}-down";
      };
    };
in
{
  imports = [ ./systemd.nix ];

  options.vpnNamespaces = mkOption {
    type = attrsOf (submodule [ (import ./options.nix) ]);
    default = { };
    description = ''
      VPN network namespaces. Each namespace creates an isolated
      networking environment with a WireGuard tunnel, connected to the
      host via a veth pair and linux bridge.

      Services can be confined to a namespace using
      systemd.services.<name>.vpnConfinement.
    '';
  };

  config = mkIf (config.vpnNamespaces != { }) {
    assertions = [
      {
        assertion = config.boot.kernel.sysctl."net.ipv4.ip_forward" == 1;
        message = ''
          vpnNamespaces requires net.ipv4.ip_forward = 1, but it is set
          to ${toString config.boot.kernel.sysctl."net.ipv4.ip_forward"}.
          The VPN namespace uses a bridge + veth pair for LAN connectivity,
          which requires IP forwarding on the host.
        '';
      }
    ];

    # mkDefault (priority 1000) avoids conflicts when another module
    # also sets ip_forward = 1. The assertion above catches the case
    # where something overrides it to a different value.
    boot.kernel.sysctl."net.ipv4.ip_forward" = lib.mkDefault 1;
    boot.kernel.sysctl."net.ipv6.conf.all.forwarding" =
      mkIf isIPv6Enabled (lib.mkDefault 1);

    systemd.services =
      mapAttrs' (n: v: nameValuePair n (namespaceToService n v))
        config.vpnNamespaces;

    # Ensure /run/resolvconf exists so that InaccessiblePaths doesn't
    # fail when the path is absent (e.g., when using systemd-resolved
    # which doesn't create this directory).
    systemd.tmpfiles.rules = [ "d /run/resolvconf 0755 root root" ];
  };
}
