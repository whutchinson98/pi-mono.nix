{
  description = "pi coding agent (fork of earendil-works/pi)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        pi-coding-agent = pkgs.callPackage ./package.nix { src = self; };
        default = pi-coding-agent;
      });

      overlays.default = final: prev: {
        pi-coding-agent = final.callPackage ./package.nix { src = self; };
      };
    };
}
