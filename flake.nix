{
  description = "zix - a simple CLI tool to update your NixOS system";

  inputs.zig2nix.url = "github:Cloudef/zig2nix";

  outputs =
    { self, zig2nix, ... }:
    zig2nix.inputs.flake-utils.lib.eachDefaultSystem (
      system:
      let
        env = zig2nix.outputs.zig-env.${system} {
          zig = zig2nix.outputs.packages.${system}.zig-0_17_0;
        };
        lib = env.pkgs.lib;

        # Arguments shared by the packaged variants. `build.zig.zon` supplies
        # the pname and version, so they are not repeated here.
        base = {
          src = self;
          zigPreferMusl = true;
          meta = {
            description = "A simple CLI tool to update your NixOS system";
            homepage = "https://github.com/badwatt/zix";
            license = lib.licenses.mit;
            mainProgram = "zix";
            platforms = lib.platforms.linux;
          };
        };

        # Installable package: binary, man page and shell completions.
        default = env.package (base // {
          postInstall = ''
            install -Dm644 ${./zix.1} "$out/share/man/man1/zix.1"

            install -d "$out/share/bash-completion/completions" \
                       "$out/share/fish/vendor_completions.d" \
                       "$out/share/zsh/site-functions"
            "$out/bin/zix" --completions bash > "$out/share/bash-completion/completions/zix"
            "$out/bin/zix" --completions fish > "$out/share/fish/vendor_completions.d/zix.fish"
            "$out/bin/zix" --completions zsh  > "$out/share/zsh/site-functions/_zix"
          '';
        });

        # Raw static binary, without man page or completions.
        foreign = env.package base;

        appFor = pkg: {
          type = "app";
          program = "${pkg}/bin/zix";
        };
      in
      {
        packages = { inherit default foreign; };

        apps = {
          default = appFor default;
          static = appFor foreign;
          dev = env.app [ ] "zig build run --release=fast -- \"$@\"";
          build = env.app [ ] "zig build --release=fast \"$@\"";
          test = env.app [ ] "zig build test -- \"$@\"";
          docs = env.app [ ] "zig build docs --release=fast -- \"$@\"";
          zig2nix = env.app [ ] "zig2nix \"$@\"";
        };

        devShells.default = env.mkShell { };
      }
    );
}
