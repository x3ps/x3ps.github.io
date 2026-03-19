{
  description = "x3ps.dev Hugo blog devshell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          buildInputs = [
            pkgs.hugo
            pkgs.nodePackages.markdownlint-cli2
            pkgs.nodePackages.cspell
            pkgs.git
          ];

          shellHook = ''
            echo "Hugo: $(hugo version)"
            echo "markdownlint-cli2: $(markdownlint-cli2 --version)"
            echo "cspell: $(cspell --version)"
            if [ ! -f themes/hello-friend-ng/theme.toml ]; then
              git submodule update --init --recursive
            fi
            alias serve='hugo server -D'
            alias lint='markdownlint-cli2 "content/**/*.md" && cspell "content/**/*.md"'
            alias c='clear'
          '';
        };
      });
    };
}
