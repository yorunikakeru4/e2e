{
    description = "FrogOS e2e — interactive distro exploration environment";

    inputs = {
        nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
        flake-utils.url = "github:numtide/flake-utils";

        frogos-flake = {
            url = "git+https://git.cherdak.work/FrogOS/FrogOS";
            inputs.nixpkgs.follows = "nixpkgs";
        };

        dsl-flake = {
            url = "git+https://git.cherdak.work/FrogOS/DSL";
            inputs.nixpkgs.follows = "nixpkgs";
        };
    };

    outputs =
        {
            self,
            nixpkgs,
            flake-utils,
            frogos-flake,
            dsl-flake,
        }:
        flake-utils.lib.eachDefaultSystem (
            system:
            let
                pkgs = import nixpkgs { inherit system; };

                frogosPkg = frogos-flake.packages.${system}.default;
                dslPkg = dsl-flake.packages.${system}.default;

                mainHsTemplate = pkgs.writeText "Main.hs" ''
                    module Main (main) where

                    import Compile (compile)
                    import DSL (configuration)

                    main :: IO ()
                    main = compile $ configuration $ do
                        pure ()
                '';

                fhsEnv = pkgs.buildFHSEnv {
                    name = "frogos-e2e";

                    targetPkgs = _: [
                        frogosPkg
                        dslPkg
                        pkgs.nix
                        pkgs.dinit
                        pkgs.forgejo
                        pkgs.bash
                        pkgs.coreutils
                        pkgs.findutils
                        pkgs.gnugrep
                        pkgs.jq
                        pkgs.less
                        pkgs.procps
                        pkgs.neovim
                    ];

                    extraBwrapArgs = [
                        "--tmpfs" "/home"
                        "--dir" "/home/frogos"
                        "--tmpfs" "/frogos"
                        "--tmpfs" "/etc/dinit"
                        "--tmpfs" "/etc/frogos"
                        "--tmpfs" "/run"
                        "--chdir" "/home/frogos"
                    ];

                    runScript = pkgs.writeShellScript "e2e-entry" ''
                        set -euo pipefail

                        export HOME=/home/frogos
                        cd "$HOME"

                        mkdir -p /frogos/generations /frogos/store /etc/dinit/system /etc/frogos /run

                        cp ${mainHsTemplate} /etc/frogos/Main.hs

                        export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
                        mkdir -p "$XDG_RUNTIME_DIR"

                        printf 'type = internal\n' > /etc/dinit/system/boot

                        dinit --user --services-dir /etc/dinit/system &
                        DINIT_PID=$!
                        for _i in $(seq 1 50); do
                            [ -S "$XDG_RUNTIME_DIR/dinitctl" ] && break
                            sleep 0.1
                        done
                        [ -S "$XDG_RUNTIME_DIR/dinitctl" ] \
                            || echo "warning: dinit socket did not appear" >&2

                        frogosd &
                        FROGOSD_PID=$!
                        for _i in $(seq 1 30); do
                            [ -S /run/frogosd.sock ] && break
                            sleep 0.1
                        done

                        trap '
                            kill "$FROGOSD_PID" 2>/dev/null || true
                            kill "$DINIT_PID"   2>/dev/null || true
                            wait 2>/dev/null   || true
                        ' EXIT

                        echo ""
                        echo "=== FrogOS interactive environment ==="
                        echo "  frogosd  → /run/frogosd.sock"
                        echo "  dinit    → \$XDG_RUNTIME_DIR/dinitctl"
                        echo "  config   → /etc/frogos/Main.hs"
                        echo ""

                        if [ $# -gt 0 ]; then
                            exec "$@"
                        else
                            exec bash --login
                        fi
                    '';
                };
            in
            {
                packages = {
                    default = fhsEnv;
                    e2e = fhsEnv;
                };

                apps.default = {
                    type = "app";
                    program = "${fhsEnv}/bin/frogos-e2e";
                };
            }
        );
}
