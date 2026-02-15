{ pkgs, lib, ... }:
let
  parseWgQuick = pkgs.writeShellApplication {
    name = "parse-wg-quick";
    # Only uses bash builtins, mkdir, printf, grep, cat, wc — all in
    # the default NixOS PATH. No extra runtimeInputs needed.
    runtimeInputs = [ ];
    text = builtins.readFile ./parse-wg-quick.sh;
  };

  tests = pkgs.runCommand "parse-wg-quick-tests" {
    nativeBuildInputs = [ pkgs.bash ];
    src = lib.cleanSource ./.;
  } ''
    cd $src
    bash test-parser.sh
    touch $out
  '';

in {
  inherit parseWgQuick tests;
}
