{
  description = "NixOS module for confining systemd services to a WireGuard VPN namespace";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs, ... }:
  let
    supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
    forAllSystems = f:
      nixpkgs.lib.genAttrs supportedSystems (system:
        f {
          pkgs = nixpkgs.legacyPackages.${system};
          lib = nixpkgs.lib;
          inherit system;
        }
      );
  in {
    nixosModules = rec {
      vpnConfinement = ./modules/vpn-netns.nix;
      default = vpnConfinement;
    };

    packages = forAllSystems ({ pkgs, lib, ... }: rec {
      parse-wg-quick =
        (import ./pkgs/parse-wg-quick { inherit pkgs lib; }).parseWgQuick;
      default = parse-wg-quick;
    });

    checks = forAllSystems ({ pkgs, lib, system, ... }: {
      # Parser unit tests (requires test fixture .conf files in
      # pkgs/parse-wg-quick/tests/ — see tests/README for expected files)
      parse-wg-quick =
        (import ./pkgs/parse-wg-quick { inherit pkgs lib; }).tests;

      # NixOS VM integration tests
      integration = pkgs.testers.runNixOSTest ./tests/test.nix;
    });
  };
}
