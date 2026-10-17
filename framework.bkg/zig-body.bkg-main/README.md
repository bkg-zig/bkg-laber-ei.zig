# BKG Framework: Body

Native Zig framework and library workspace. The package manifest identifies this snapshot as version `0.1.0` and requires Zig `0.16.0` or newer. It has no declared external Zig package dependencies.

## Handoff status

The library test target passes, but the executable is **not currently buildable**. `build.zig` declares the executable root as `utils/bkg/main.zig`, but that file and the `utils/` directory are absent from both the extracted tree and the supplied `zig-body.bkg-main.zip`. Restore the CLI entry point before treating the executable or its documented commands as usable.

Zig `0.16.0` is installed user-locally and available on `PATH` in the current environment. On 2026-10-17, `zig build test` completed successfully; `zig build` failed while compiling `bkg` because `utils/bkg/main.zig` is missing. The test baseline mentioned in `docs/next-tasks.md` is historical and is not used as the current result.

## Build and test

From this directory, run the verified library tests:

```sh
zig build test
```

The test command passes with Zig 0.16.0. The executable build currently fails because its configured root source file is missing. After restoring `utils/bkg/main.zig`, run:

```sh
zig build
```

The build file intends to install an executable named `bkg` to `zig-out/bin/bkg`; that output is not available from the current snapshot.

## Intended CLI and HTTP contract

The following interface is documented by the source README, but is **not executable until the missing CLI entry point is restored and the build passes**:

```sh
./zig-out/bin/bkg init ./data
./zig-out/bin/bkg put ./data user:1 Ada
./zig-out/bin/bkg get ./data user:1
./zig-out/bin/bkg status ./data
./zig-out/bin/bkg serve ./data
```

The documented HTTP routes are:

| Method | Path | Authentication |
|---|---|---|
| GET | `/health` | None; liveness only |
| GET | `/v1/status` | Bearer token |
| GET, PUT, DELETE | `/v1/kv/<key>` | Bearer token |

The documented contract says `init` writes `./data/auth.token` with mode `0600` without printing the token; `serve` requires that file or `BKG_AUTH_TOKEN` and binds to `127.0.0.1` by default. Treat these as unverified until an end-to-end CLI test is possible.

## Module map

These module names and source roots are declared in `build.zig`; their runtime readiness is not implied by registration alone.

| Module | Responsibility indicated by the source tree |
|---|---|
| `bkg-core` | Shared errors, identifiers, and clock utilities |
| `bkg-db` | Database, storage, ledger, protocol, and evolution code |
| `bkg-vault` | Cryptography, password hashing, random generation, and secret storage |
| `bkg-auth` | Passwords, sessions, JWT, RBAC, and Bearer authentication |
| `bkg-web` | HTTP server, routing, and middleware |
| `bkg-config` | Environment, TOML parsing, and configuration validation |
| `bkg-cli` | Command and flag parsing, output helpers |
| `bkg-http` | HTTP client library |
| `bkg-events` | Event library |
| `bkg-metrics` | Metrics library |
| `bkg-tui` | Terminal UI library |
| `bkg-docker` | Docker Unix-socket client and stream handling |
| `bkg-ws` | WebSocket library |
| `bkg-license` | License library |
| `bkg-model-*` | BKG Model Layer components |

## Configuration and security notes

The README and source describe these environment variables for the intended service: `BKG_BIND`, `BKG_PORT`, `BKG_AUTH_TOKEN`, and `BKG_TOKEN_FILE`. The documented security constraints include default-deny Bearer authentication, Argon2id password hashing, HS256-only JWT validation, AES-256-GCM vault encryption, and fail-closed decryption. These behaviors have not been exercised in this environment.

Avoid passing secrets as command-line arguments. The documented server interface uses `BKG_AUTH_TOKEN` or the token file instead.

## Repository guide

- `libs/`: library implementations and module tests.
- `docs/ARCHITECTURE-V5.md`: architecture overview.
- `docs/MODEL_LAYER_v1.md`: model-layer design.
- `docs/BKGDB_EVOLUTION_MEMORY_v1.md` and related `BKGDB_EVOLUTION_MEMORY_*` files: database evolution design notes.
- `docs/next-tasks.md`: task history and a historical test baseline; confirm dates and status before using it as current project state.

## Frozen areas

Do not edit these without an explicit protocol-level reason:

- `libs/bkg-db/src/crypto/envelope.zig`
- `libs/bkg-db/src/crypto/keyring.zig`
- `libs/bkg-db/src/storage/wal_encrypted.zig`
- BKG Model Layer
# zig-body.bkg
