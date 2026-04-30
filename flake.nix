{
  description = "Telegram bot that tracks nixpkgs PRs across channel branches";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        nixprbot = pkgs.callPackage ./nix/package.nix { };
        default = nixprbot;
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [ zig zls sqlite zon2nix ];
        };
      });

      nixosModules.default = import ./nix/module.nix self;
      nixosModules.nixprbot = self.nixosModules.default;
    };
}
