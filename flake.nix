{
  description = "Build Debian packages from NIX";

  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
  inputs.poetry2nix = {
    url = "github:nix-community/poetry2nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  inputs.bampkgbuild.url = "github:brianmay/bampkgbuild";

  outputs = { self, nixpkgs, flake-utils, poetry2nix, bampkgbuild }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        p2n = import poetry2nix { inherit pkgs; };
        overrides = p2n.defaultPoetryOverrides.extend (self: super: {
          gbp = super.gbp.overridePythonAttrs (old: {
            buildInputs = (old.buildInputs or [ ])
              ++ [ super.setuptools super.nosexcover ];
          });
        });

        poetry_env = p2n.mkPoetryEnv {
          python = pkgs.python3;
          projectDir = self;
          inherit overrides;
        };
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.dpkg
            pkgs.debian-devscripts
            pkgs.poetry
            poetry_env
            bampkgbuild.packages.${system}.default
          ];
        };
      });
}
