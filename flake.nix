{
  description = "FrogOS e2e — interactive distro exploration environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    frogos-flake = {
      url = "git+https://git.cherdak.work/FrogOS/FrogOS";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.toad-src.follows = "toad-src";
    };

    toad-src = {
      url = "git+https://git.cherdak.work/FrogOS/Toad";
      flake = false;
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
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        frogosPkg = frogos-flake.packages.${system}.default;

        # ── /etc/frogos/ cabal project templates ──────────────────────────────

        cabalProjectTemplate = pkgs.writeText "cabal.project" ''
          packages: .

          source-repository-package
            type:     git
            location: https://git.cherdak.work/FrogOS/DSL.git
            tag:      main

          source-repository-package
            type:     git
            location: https://git.cherdak.work/FrogOS/IR.git
            tag:      main
        '';

        frogosConfigCabal = pkgs.writeText "frogos-config.cabal" ''
          cabal-version: 3.0
          name:          frogos-config
          version:       0.1.0

          executable frogos-config
            main-is:          Main.hs
            other-modules:    Gaming, ServerStack, Users
            build-depends:    base, DSL, bytestring
            hs-source-dirs:   .
            default-language: Haskell2010
        '';

        mainHsTemplate = pkgs.writeText "Main.hs" ''
          module Main (main) where

          import Compile (compile)
          import DSL (configuration)
          import Gaming (gaming)
          import ServerStack (serverStack)
          import Users (users)

          main :: IO ()
          main = compile $ configuration $ do
              gaming
              serverStack
              users
        '';

        gamingHsTemplate = pkgs.writeText "Gaming.hs" ''
          {-# LANGUAGE OverloadedStrings #-}

          module Gaming where

          import Builder (ConfigBuilder)
          import Condition (poll, processRunning, via)
          import DSL (profile, when)
          import Module (disable, nginx)
          import Power (PowerProfile (Performance), setPowerProfile)

          gaming :: ConfigBuilder ()
          gaming = profile "gaming" $
              when (processRunning "steam" `via` poll 500) $ do
                  disable nginx
                  setPowerProfile Performance
        '';

        serverStackHsTemplate = pkgs.writeText "ServerStack.hs" ''
          {-# LANGUAGE OverloadedStrings #-}

          module ServerStack where

          import Builder (ConfigBuilder)
          import qualified Module.Forgejo as Fj
          import qualified Module.Nginx as Nginx
          import qualified Module.Nginx.VirtualHost as NginxVH
          import qualified Module.PostgreSQL as PG
          import Port (port, withFallback)

          serverStack :: ConfigBuilder ()
          serverStack = do
              Nginx.nginxModule $ do
                  Nginx.enable True
                  Nginx.virtualHost "example.com" $ do
                      NginxVH.httpPort (80 `withFallback` [800])
                      NginxVH.httpsPort (443 `withFallback` [80])

              Fj.forgejoModule $ do
                  Fj.enable True
                  Fj.httpPort (port 3000)
                  Fj.sshPort (port 2222)
                  Fj.domain "git.example.com"

              PG.postgresqlModule $ do
                  PG.enable True
                  PG.port (port 5432)
                  PG.dataDir "/var/lib/postgresql/data"
                  PG.maxConnections 100
        '';

        usersHsTemplate = pkgs.writeText "Users.hs" ''
          {-# LANGUAGE OverloadedStrings #-}

          module Users where

          import Builder (ConfigBuilder)
          import User

          users :: ConfigBuilder ()
          users = do
              user "alice" $ do
                  isNormalUser True
                  description "Primary user"
                  extraGroups ["networkmanager", "wheel", "docker"]
                  packages ["steam", "wine"]

              user "bob" $ do
                  isNormalUser False
                  description "Service account"
        '';

        fhsEnv = pkgs.buildFHSEnv {
          name = "frogos-e2e";

          targetPkgs = _: [
            frogosPkg
            pkgs.cabal-install
            pkgs.haskellPackages.ghc
            pkgs.git
            pkgs.nix
            pkgs.dinit
            pkgs.bash
            pkgs.coreutils
            pkgs.findutils
            pkgs.gnugrep
            pkgs.jq
            pkgs.less
            pkgs.procps
          ];

          extraBwrapArgs = [
            "--tmpfs"
            "/home"
            "--dir"
            "/home/frogos"
            "--tmpfs"
            "/frogos"
            "--tmpfs"
            "/etc/dinit"
            "--tmpfs"
            "/etc/frogos"
            "--tmpfs"
            "/run"
            "--chdir"
            "/home/frogos"
          ];

          runScript = pkgs.writeShellScript "e2e-entry" ''
            set -euo pipefail

            export HOME=/home/frogos
            cd "$HOME"

            mkdir -p /frogos/generations /frogos/store /etc/dinit/system /etc/frogos /run
            export FROGOS_GENERATIONS_DIR=/frogos/generations

            cp ${cabalProjectTemplate}   /etc/frogos/cabal.project
            cp ${frogosConfigCabal}      /etc/frogos/frogos-config.cabal
            cp ${mainHsTemplate}         /etc/frogos/Main.hs
            cp ${gamingHsTemplate}       /etc/frogos/Gaming.hs
            cp ${serverStackHsTemplate}  /etc/frogos/ServerStack.hs
            cp ${usersHsTemplate}        /etc/frogos/Users.hs

            echo "Updating Hackage package list..."
            cabal update

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
            echo "  config   → /etc/frogos/  (edit freely)"
            echo ""
            echo "  note: first 'frogos apply' compiles DSL from source (~1-2 min)"
            echo "        subsequent runs use cabal cache"
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
