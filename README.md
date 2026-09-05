# FrogOS e2e

End-to-end interactive exploration environment for FrogOS.

This flake builds a [FHS environment](https://nixos.org/manual/nixpkgs/stable/)
that wires up the full FrogOS stack — daemon (`frogosd`), service manager
(dinit), the compiled DSL, and the actor runtime — so you can experiment with
`frogos apply` against a live system.

## Usage

```bash
nix run .#e2e
```

Inside the environment:

```text
frogosd  → /run/frogosd.sock   (daemon socket)
dinit    → dinitctl             (service manager)
config   → /etc/frogos/         (edit freely, then apply)
```

```bash
frogos apply /etc/frogos/configuration.frog
frogos watch                     # stream live daemon logs
```

The first `frogos apply` compiles the DSL from source (~1–2 min); subsequent
runs use the cabal cache.

The environment is designed to be disposable — exit the shell and the trap
shuts down `frogosd` and dinit for you.

## Development

```bash
nix flake check
```

The flake depends on the FrogOS, DSL, and Toad component flakes. See
[flake.nix](flake.nix) for the full wiring.