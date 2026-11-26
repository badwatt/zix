{
  description = "zix - a simple CLI tool to update your NixOS system";

  inputs.zig2nix.url = "github:Cloudef/zig2nix";

  outputs =
    { self, zig2nix, ... }:
    zig2nix.inputs.flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (
      system:
      let
        env = zig2nix.outputs.zig-env.${system} {
          zig = zig2nix.outputs.packages.${system}.zig-0_17_0;
        };
        lib = env.pkgs.lib;

        # build.zig.zon stays the single source of truth, but it is read with
        # plain Nix instead of letting zig2nix build and run zon2json at eval
        # time: that import-from-derivation cannot run when cross-evaluating
        # another architecture (an aarch64 config from an x86_64 machine, for
        # example). The pinned zigTarget skips zig2nix's `target` IFD too.
        zonFlat = lib.replaceStrings [ "\n" "\r" ] [ " " " " ] (builtins.readFile ./build.zig.zon);
        zonField =
          field: re:
          let
            found = builtins.match re zonFlat;
          in
          if found == null then
            throw "flake.nix: build.zig.zon does not declare ${field}"
          else
            builtins.head found;

        # Arguments shared by the packaged variants.
        base = {
          src = self;
          pname = zonField "name" ".*\\.name[[:space:]]*=[[:space:]]*\\.([A-Za-z0-9_]+).*";
          version = zonField "version" ".*\\.version[[:space:]]*=[[:space:]]*\"([^\"]+)\".*";
          zigPreferMusl = true;
          zigTarget = "${system}-musl";
          meta = {
            description = "A simple CLI tool to update your NixOS system";
            homepage = "https://github.com/badwatt/zix";
            license = lib.licenses.mit;
            mainProgram = "zix";
            platforms = lib.platforms.linux;
          };
        };

        # Installable package: binary, man page and shell completions.
        default = env.package (
          base
          // {
            postInstall = ''
              install -Dm644 ${./zix.1} "$out/share/man/man1/zix.1"

              install -d "$out/share/bash-completion/completions" \
                         "$out/share/fish/vendor_completions.d" \
                         "$out/share/zsh/site-functions"
              "$out/bin/zix" --completions bash > "$out/share/bash-completion/completions/zix"
              "$out/bin/zix" --completions fish > "$out/share/fish/vendor_completions.d/zix.fish"
              "$out/bin/zix" --completions zsh  > "$out/share/zsh/site-functions/_zix"
            '';
          }
        );

        # Raw static binary, without man page or completions.
        foreign = env.package base;

        appFor = pkg: {
          type = "app";
          program = "${pkg}/bin/zix";
        };
      in
      {
        packages = { inherit default foreign; };

        checks.default = default;

        formatter = env.pkgs.nixfmt;

        # Static binaries for other architectures, built with Zig's cross
        # compiler (no binfmt or remote builder needed).
        legacyPackages.cross = {
          x86_64-linux-musl = env.package (base // { zigTarget = "x86_64-linux-musl"; });
          aarch64-linux-musl = env.package (base // { zigTarget = "aarch64-linux-musl"; });
        };

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
