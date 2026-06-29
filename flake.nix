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
            build-depends:    base, DSL, bytestring
            hs-source-dirs:   .
            default-language: Haskell2010
        '';

        mainHsTemplate = pkgs.writeText "Main.hs" ''
          {-# LANGUAGE OverloadedStrings #-}

          module Main (main) where

          import Compile (compile)
          import DSL (configuration, systemPackages)
          import Module.Virtualization
          import User (extraGroups, isNormalUser, packages, user)

          main :: IO ()
          main = compile $ configuration $ do
              user "yorunikakeru" $ do
                  isNormalUser True
                  extraGroups ["networkmanager", "wheel", "docker"]
                  packages ["btop"]

              virtualizationModule $ do
                  enable True

              systemPackages ["dust", "tetris"]
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
            pkgs.shadow # provides groupadd/useradd/groupdel/userdel
            pkgs.sudo
            pkgs.cacert
            pkgs.neovim
          ];

          # Replace individual /etc/* tmpfs mounts with a single writable /etc.
          # This lets groupadd/useradd/groupdel/userdel write to /etc/group and
          # /etc/passwd, which are otherwise read-only Nix-store bind mounts.
          extraBwrapArgs = [
            "--unshare-user"
            "--uid"
            "0"
            "--gid"
            "0"

            "--tmpfs"
            "/home"
            "--dir"
            "/home/frogos"

            "--tmpfs"
            "/frogos"

            "--tmpfs"
            "/etc"

            "--tmpfs"
            "/run"

            "--tmpfs"
            "/var"

            "--chdir"
            "/home/frogos"
          ];

          runScript = pkgs.writeShellScript "e2e-entry" ''
            # Set PATH before anything else: /etc/profile is absent until we create
            # it below, so /init's attempt to source it leaves PATH unset.
            export PATH="/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"
            set -euo pipefail

            # ── writable /var ─────────────────────────────────────────────────
            mkdir -p /var/log /var/lib /var/tmp
            chown 0:0 /var /var/log /var/lib /var/tmp
            chmod 755 /var /var/log /var/lib
            chmod 1777 /var/tmp

            # Docker creates transient libnetwork sockets under exec-root.
            # Pre-create them with sandbox-friendly permissions so bind(2)
            # does not fail under the user namespace.
            mkdir -p /run/docker/libnetwork
            chown -R 0:0 /run/docker
            chmod 1777 /run/docker /run/docker/libnetwork

            # ── writable /etc ─────────────────────────────────────────────────
            mkdir -p /etc/ssl/certs /etc/dinit/system /etc/frogos /etc/ld.so.conf.d /etc/docker

            cd /etc/frogos

            # Restore /etc/profile so interactive shells get a working PATH.
            printf 'export PATH="/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"\n' \
              > /etc/profile

            # DNS (public resolvers for the sandbox)
            printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf

            # Hosts
            printf '127.0.0.1 localhost\n::1 localhost\n' > /etc/hosts

            # NSS
            printf 'passwd: files\ngroup: files\nshadow: files\nhosts: files dns\n' > /etc/nsswitch.conf

            # Docker can start in this unprivileged e2e sandbox, but it cannot
            # manage host firewall/NAT state. Keep the daemon alive for module
            # lifecycle testing without requiring netfilter capabilities.
            cat > /etc/docker/daemon.json <<'EOF'
            {
              "bridge": "none",
              "exec-root": "/run/docker",
              "ipv6": false,
              "iptables": false,
              "ip6tables": false,
              "ip-forward": false,
              "ip-masq": false,
              "storage-driver": "vfs"
            }
            EOF

            # CA certs (referenced by Nix store path baked in at build time)
            ln -sf ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt
            export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            export NIX_SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"

            # Keep the shell identity in desired state so Planner never removes it.
            printf 'root:x:0:0:root:/root:/bin/sh\nfrogos:x:1000:0:frogos:/home/frogos:/bin/sh\n' > /etc/passwd
            # The e2e user namespace only maps gid 0. Keep FrogOS-managed groups
            # on gid 0 so daemons can chown sockets to them inside the sandbox.
            printf 'root:x:0:frogos\ndocker:x:0:frogos\nnetworkmanager:x:0:frogos\nwheel:x:0:frogos\n' > /etc/group
            printf 'root:*:19770:0:99999:7:::\nfrogos:*:19770:0:99999:7:::\n' > /etc/shadow
            printf 'root:!::frogos\n' > /etc/gshadow
            chmod 640 /etc/shadow /etc/gshadow

            # ── generation store ───────────────────────────────────────────────
            mkdir -p /frogos/store/generations /frogos/store/packages

            # ── config templates ───────────────────────────────────────────────
            cp ${cabalProjectTemplate}   /etc/frogos/cabal.project
            cp ${frogosConfigCabal}      /etc/frogos/frogos-config.cabal
            cp ${mainHsTemplate}         /etc/frogos/Main.hs

            # ── Hackage index ──────────────────────────────────────────────────
            echo "Updating Hackage package list..."
            cabal update

            export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
            mkdir -p "$XDG_RUNTIME_DIR"

            # ── dinit ──────────────────────────────────────────────────────────
            mkdir -p /etc/dinit/system/boot.d
            printf 'type = internal\nwaits-for.d = /etc/dinit/system/boot.d\n' > /etc/dinit/system/boot

            dinit --user --services-dir /etc/dinit/system &
            DINIT_PID=$!
            for _i in $(seq 1 50); do
                [ -S "$XDG_RUNTIME_DIR/dinitctl" ] && break
                sleep 0.1
            done
            [ -S "$XDG_RUNTIME_DIR/dinitctl" ] \
                || echo "warning: dinit socket did not appear" >&2
            [ -S "$XDG_RUNTIME_DIR/dinitctl" ] \
                && ln -sf "$XDG_RUNTIME_DIR/dinitctl" /run/dinitctl

            # ── frogosd (logs to /run/frogosd.log) ────────────────────────────
            frogosd 2>/run/frogosd.log &
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
            echo "        use 'frogos watch' to stream live daemon logs"
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
