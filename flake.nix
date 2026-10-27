{
  description = "Zig project flake";

  inputs = {
    zig2nix.url = "github:Cloudef/zig2nix";
  };

  outputs =
    { zig2nix, ... }:
    let
      flake-utils = zig2nix.inputs.flake-utils;
    in
    (flake-utils.lib.eachDefaultSystem (
      system:
      let
        env = zig2nix.outputs.zig-env.${system} { zig = zig2nix.outputs.packages.${system}.zig-0_17_0; };
      in
      with builtins;
      with env.pkgs.lib;
      rec {
        packages.foreign = env.package (
          {
            src = cleanSource ./.;

            nativeBuildInputs = with env.pkgs; [ ];

            buildInputs = with env.pkgs; [ ];

            zigPreferMusl = true;

            zigDisableWrap = true;
          }
          // optionalAttrs (!pathExists ./build.zig.zon) {
            pname = "zix";
            version = "0.0.0";
          }
        );

        packages.default = packages.foreign.overrideAttrs (attrs: {
          zigPreferMusl = false;

          zigWrapperBins = with env.pkgs; [ ];

          zigWrapperLibs = with env.pkgs; [ ];

          postInstall = ''
            install -Dm644 ${./zix.1} "$out/share/man/man1/zix.1"
          '';
        });

        apps.bundle = {
          type = "app";
          program = "${packages.foreign}/bin/default";
        };

        # nix run .
        apps.default = env.app [ ] "zig build run --release=fast -- \"$@\"";

        # nix run .#build
        apps.build = env.app [ ] "zig build --release=fast \"$@\"";

        # nix run .#test
        apps.test = env.app [ ] "zig build test --release=fast -- \"$@\"";

        # nix run .#docs
        apps.docs = env.app [ ] "zig build docs --release=fast -- \"$@\"";

        # nix run .#zig2nix
        apps.zig2nix = env.app [ ] "zig2nix \"$@\"";

        # nix develop
        devShells.default = env.mkShell {
          nativeBuildInputs = with env.pkgs; [ ];
        };
      }
    ));
}
