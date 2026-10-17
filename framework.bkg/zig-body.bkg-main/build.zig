const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bkg_core = b.addModule("bkg-core", .{ .root_source_file = b.path("libs/bkg-core/src/bkg_core.zig") });
    const bkg_vault = b.addModule("bkg-vault", .{ .root_source_file = b.path("libs/bkg-vault/src/bkg_vault.zig") });
    bkg_vault.addImport("bkg-core", bkg_core);
    const bkg_web = b.addModule("bkg-web", .{ .root_source_file = b.path("libs/bkg-web/src/bkg_web.zig") });
    bkg_web.addImport("bkg-core", bkg_core);
    const bkg_db = b.addModule("bkg-db", .{ .root_source_file = b.path("libs/bkg-db/src/bkg_db.zig") });
    bkg_db.addImport("bkg-core", bkg_core);
    const bkg_auth = b.addModule("bkg-auth", .{ .root_source_file = b.path("libs/bkg-auth/src/bkg_auth.zig") });
    bkg_auth.addImport("bkg-core", bkg_core);
    bkg_auth.addImport("bkg-vault", bkg_vault);
    bkg_web.addImport("bkg-auth", bkg_auth);
    const bkg_http = b.addModule("bkg-http", .{ .root_source_file = b.path("libs/bkg-http/src/bkg_http.zig") });
    bkg_http.addImport("bkg-core", bkg_core);
    const bkg_events = b.addModule("bkg-events", .{ .root_source_file = b.path("libs/bkg-events/src/bkg_events.zig") });
    bkg_events.addImport("bkg-core", bkg_core);
    const bkg_metrics = b.addModule("bkg-metrics", .{ .root_source_file = b.path("libs/bkg-metrics/src/bkg_metrics.zig") });
    bkg_metrics.addImport("bkg-core", bkg_core);
    const bkg_config = b.addModule("bkg-config", .{ .root_source_file = b.path("libs/bkg-config/src/bkg_config.zig") });
    bkg_config.addImport("bkg-core", bkg_core);
    const bkg_cli = b.addModule("bkg-cli", .{ .root_source_file = b.path("libs/bkg-cli/src/bkg_cli.zig") });
    bkg_cli.addImport("bkg-core", bkg_core);
    const bkg_tui = b.addModule("bkg-tui", .{ .root_source_file = b.path("libs/bkg-tui/src/bkg_tui.zig") });
    bkg_tui.addImport("bkg-core", bkg_core);
    const bkg_docker = b.addModule("bkg-docker", .{ .root_source_file = b.path("libs/bkg-docker/src/bkg_docker.zig") });
    _ = bkg_docker; // Kein Framework-Import — standalone Unix-Socket-Lib
    const bkg_ws = b.addModule("bkg-ws", .{ .root_source_file = b.path("libs/bkg-ws/src/bkg_ws.zig") });
    _ = bkg_ws; // Kein Framework-Import — standalone WebSocket-Lib
    const bkg_license = b.addModule("bkg-license", .{ .root_source_file = b.path("libs/bkg-license/src/bkg_license.zig") });

    // Sub-modules für bkg-db Protocol/Engine (für standalone test roots benötigt)
    // Import-Schlüssel müssen exakt den @import()-Strings in den Quelldateien entsprechen.
    const bkg_db_proto_ids    = b.addModule("bkg-db-proto-ids",    .{ .root_source_file = b.path("libs/bkg-db/src/protocol/ids.zig") });
    const bkg_db_proto_events = b.addModule("bkg-db-proto-events", .{ .root_source_file = b.path("libs/bkg-db/src/protocol/events.zig") });
    const bkg_db_proto_state  = b.addModule("bkg-db-proto-state",  .{ .root_source_file = b.path("libs/bkg-db/src/protocol/state.zig") });
    bkg_db_proto_state.addImport("ids.zig", bkg_db_proto_ids);
    const bkg_db_proto_ledger = b.addModule("bkg-db-proto-ledger", .{ .root_source_file = b.path("libs/bkg-db/src/protocol/ledger.zig") });
    bkg_db_proto_ledger.addImport("ids.zig",    bkg_db_proto_ids);
    bkg_db_proto_ledger.addImport("events.zig", bkg_db_proto_events);
    const bkg_db_seg_merkle   = b.addModule("bkg-db-seg-merkle",   .{ .root_source_file = b.path("libs/bkg-db/src/engine/segment_merkle.zig") });
    const bkg_db_segment      = b.addModule("bkg-db-segment",      .{ .root_source_file = b.path("libs/bkg-db/src/engine/segment.zig") });
    bkg_db_segment.addImport("segment_merkle.zig", bkg_db_seg_merkle);
    const bkg_db_p2p_proto    = b.addModule("bkg-db-p2p-proto",    .{ .root_source_file = b.path("libs/bkg-db/src/p2p/p2p_protocol.zig") });
    bkg_db_p2p_proto.addImport("segment_merkle.zig", bkg_db_seg_merkle);
    bkg_db_p2p_proto.addImport("segment.zig",        bkg_db_segment);
    const bkg_db_genesis      = b.addModule("bkg-db-genesis",      .{ .root_source_file = b.path("libs/bkg-db/src/genesis/genesis.zig") });
    bkg_db.addImport("segment_merkle.zig", bkg_db_seg_merkle);
    bkg_db.addImport("segment.zig", bkg_db_segment);

    const test_step = b.step("test", "Run all BKG tests");
    const crypto_envelope_step = b.step("bkg-db-crypto-envelope", "Run BKGDB Encryption Envelope v1 tests");
    const storage_wal_test_step = b.step("test-storage-wal", "Run isolated BKGDB v1.2 WAL tests");
    const all_libs = .{
        .{ "bkg-core",    "libs/bkg-core/src/bkg_core.zig" },
        .{ "bkg-vault",   "libs/bkg-vault/src/bkg_vault.zig" },
        .{ "bkg-web",     "libs/bkg-web/src/bkg_web.zig" },
        .{ "bkg-auth",    "libs/bkg-auth/src/bkg_auth.zig" },
        .{ "bkg-http",    "libs/bkg-http/src/bkg_http.zig" },
        .{ "bkg-events",  "libs/bkg-events/src/bkg_events.zig" },
        .{ "bkg-metrics", "libs/bkg-metrics/src/bkg_metrics.zig" },
        .{ "bkg-config",  "libs/bkg-config/src/bkg_config.zig" },
        .{ "bkg-cli",     "libs/bkg-cli/src/bkg_cli.zig" },
        .{ "bkg-tui",     "libs/bkg-tui/src/bkg_tui.zig" },
    };
    inline for (all_libs) |lib| {
        const t = b.addTest(.{ .name = lib[0], .root_module = b.createModule(.{
            .root_source_file = b.path(lib[1]),
            .target = target, .optimize = optimize,
        })});
        t.root_module.addImport("bkg-core", bkg_core);
        if (comptime std.mem.eql(u8, lib[0], "bkg-auth") or std.mem.eql(u8, lib[0], "bkg-web")) {
            t.root_module.addImport("bkg-vault", bkg_vault);
        }
        if (comptime std.mem.eql(u8, lib[0], "bkg-web")) {
            t.root_module.addImport("bkg-auth", bkg_auth);
        }
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    // ── bkg-license: Lizenzvalidierung + Verwaltung ──────────────────────────
    {
        const t = b.addTest(.{ .name = "bkg-license", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-license/src/bkg_license.zig"),
            .target = target, .optimize = optimize,
        })});
        _ = bkg_license;
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    // ── bkg-ws: Native WebSocket-Bibliothek (RFC 6455) ───────────────────────
    {
        const t = b.addTest(.{ .name = "bkg-ws", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-ws/src/bkg_ws.zig"),
            .target = target, .optimize = optimize,
        })});
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    // ── bkg-docker: standalone Unix-Socket-Client, stream, demux ────────────
    {
        const t = b.addTest(.{ .name = "bkg-docker-client", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-docker/src/client.zig"),
            .target = target, .optimize = optimize,
        })});
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    {
        const t = b.addTest(.{ .name = "bkg-docker-stream", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-docker/src/stream.zig"),
            .target = target, .optimize = optimize,
        })});
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    {
        const t = b.addTest(.{ .name = "bkg-docker-demux", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-docker/src/demux.zig"),
            .target = target, .optimize = optimize,
        })});
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    // bkg-db: p2p_protocol.zig importiert segment_merkle.zig und segment.zig als Modul-Namen.
    // Diese Imports werden über das Modul-System aufgelöst — die Module dürfen aber
    // nicht dieselbe Datei-Root wie bkg_db_seg_merkle/bkg_db_segment haben,
    // sonst entstehen Modul-Kollisionen. Daher: eigenständige anonyme Module für bkg-db.
    {
        const bkg_db_seg_merkle_local = b.addModule("bkg-db-seg-merkle-local", .{
            .root_source_file = b.path("libs/bkg-db/src/engine/segment_merkle.zig"),
        });
        const bkg_db_segment_local = b.addModule("bkg-db-segment-local", .{
            .root_source_file = b.path("libs/bkg-db/src/engine/segment.zig"),
        });
        bkg_db_segment_local.addImport("segment_merkle.zig", bkg_db_seg_merkle_local);

        const t = b.addTest(.{ .name = "bkg-db", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-db/src/bkg_db.zig"),
            .target = target, .optimize = optimize,
        })});
        t.root_module.addImport("bkg-core", bkg_core);
        t.root_module.addImport("segment_merkle.zig", bkg_db_seg_merkle_local);
        t.root_module.addImport("segment.zig",        bkg_db_segment_local);
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Durable KV/ledger layer: standalone roots so crash-recovery tests are
    // actually compiled and executed (imported tests are not a substitute).
    {
        const t = b.addTest(.{ .name = "bkg-db-ledger", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-db/src/ledger.zig"),
            .target = target, .optimize = optimize,
        })});
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    {
        const t = b.addTest(.{ .name = "bkg-db-wal", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-db/src/wal.zig"),
            .target = target, .optimize = optimize,
        })});
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    {
        const t = b.addTest(.{ .name = "bkg-db-storage-pages", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-db/src/storage.zig"),
            .target = target, .optimize = optimize,
        })});
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    {
        const t = b.addTest(.{ .name = "bkg-db-txn", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-db/src/txn.zig"),
            .target = target, .optimize = optimize,
        })});
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    {
        const t = b.addTest(.{ .name = "bkg-db-engine", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-db/src/engine.zig"),
            .target = target, .optimize = optimize,
        })});
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    {
        const t = b.addTest(.{ .name = "bkg-db-btree", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-db/src/btree.zig"),
            .target = target, .optimize = optimize,
        })});
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Protocol + Engine + P2P Tests (standalone, mit expliziten Module-Imports)
    {
        const t = b.addTest(.{ .name = "bkg-db-protocol-ids", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-db/src/protocol/ids.zig"),
            .target = target, .optimize = optimize,
        })});
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    {
        const t = b.addTest(.{ .name = "bkg-db-protocol-events", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-db/src/protocol/events.zig"),
            .target = target, .optimize = optimize,
        })});
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    {
        const t = b.addTest(.{ .name = "bkg-db-protocol-state", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-db/src/protocol/state.zig"),
            .target = target, .optimize = optimize,
        })});
        t.root_module.addImport("ids.zig", bkg_db_proto_ids);
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    {
        const t = b.addTest(.{ .name = "bkg-db-protocol-ledger", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-db/src/protocol/ledger.zig"),
            .target = target, .optimize = optimize,
        })});
        t.root_module.addImport("ids.zig",    bkg_db_proto_ids);
        t.root_module.addImport("events.zig", bkg_db_proto_events);
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    {
        const t = b.addTest(.{ .name = "bkg-db-genesis", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-db/src/genesis/genesis.zig"),
            .target = target, .optimize = optimize,
        })});
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    {
        const t = b.addTest(.{ .name = "bkg-db-engine-rebuild", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-db/src/engine/rebuild.zig"),
            .target = target, .optimize = optimize,
        })});
        t.root_module.addImport("../protocol/ledger.zig", bkg_db_proto_ledger);
        t.root_module.addImport("../protocol/state.zig",  bkg_db_proto_state);
        t.root_module.addImport("../genesis/genesis.zig", bkg_db_genesis);
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    {
        const t = b.addTest(.{ .name = "bkg-db-engine-ledger-wal", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-db/src/engine/ledger_wal.zig"),
            .target = target, .optimize = optimize,
        })});
        t.root_module.addImport("../protocol/ledger.zig",  bkg_db_proto_ledger);
        t.root_module.addImport("../protocol/state.zig",   bkg_db_proto_state);
        t.root_module.addImport("../protocol/events.zig",  bkg_db_proto_events);
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    {
        const t = b.addTest(.{ .name = "bkg-db-engine-seg-merkle", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-db/src/engine/segment_merkle.zig"),
            .target = target, .optimize = optimize,
        })});
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    {
        const seg_merkle_for_segment_test = b.addModule("bkg-db-seg-merkle-for-seg-test", .{
            .root_source_file = b.path("libs/bkg-db/src/engine/segment_merkle.zig"),
        });
        const t = b.addTest(.{ .name = "bkg-db-engine-segment", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-db/src/engine/segment.zig"),
            .target = target, .optimize = optimize,
        })});
        t.root_module.addImport("segment_merkle.zig", seg_merkle_for_segment_test);
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    {
        // rebuild.zig und ledger_wal.zig als wiederverwendbare Module (nicht neue Roots)
        const bkg_db_rebuild = b.addModule("bkg-db-rebuild", .{
            .root_source_file = b.path("libs/bkg-db/src/engine/rebuild.zig"),
        });
        bkg_db_rebuild.addImport("../protocol/ledger.zig", bkg_db_proto_ledger);
        bkg_db_rebuild.addImport("../protocol/state.zig",  bkg_db_proto_state);
        bkg_db_rebuild.addImport("../genesis/genesis.zig", bkg_db_genesis);
        const bkg_db_ledger_wal = b.addModule("bkg-db-ledger-wal", .{
            .root_source_file = b.path("libs/bkg-db/src/engine/ledger_wal.zig"),
        });
        bkg_db_ledger_wal.addImport("../protocol/ledger.zig",  bkg_db_proto_ledger);
        bkg_db_ledger_wal.addImport("../protocol/state.zig",   bkg_db_proto_state);
        bkg_db_ledger_wal.addImport("../protocol/events.zig",  bkg_db_proto_events);

        const t = b.addTest(.{ .name = "bkg-db-engine-proof", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-db/src/engine/ledger_proof.zig"),
            .target = target, .optimize = optimize,
        })});
        t.root_module.addImport("../protocol/ledger.zig",  bkg_db_proto_ledger);
        t.root_module.addImport("../protocol/state.zig",   bkg_db_proto_state);
        t.root_module.addImport("../p2p/p2p_protocol.zig", bkg_db_p2p_proto);
        t.root_module.addImport("../genesis/genesis.zig",  bkg_db_genesis);
        t.root_module.addImport("rebuild.zig",             bkg_db_rebuild);
        t.root_module.addImport("ledger_wal.zig",          bkg_db_ledger_wal);
        t.root_module.addImport("segment_merkle.zig",      bkg_db_seg_merkle);
        t.root_module.addImport("segment.zig",             bkg_db_segment);
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    {
        const t = b.addTest(.{ .name = "bkg-db-p2p-protocol", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-db/src/p2p/p2p_protocol.zig"),
            .target = target, .optimize = optimize,
        })});
        t.root_module.addImport("segment_merkle.zig", bkg_db_seg_merkle);
        t.root_module.addImport("segment.zig",        bkg_db_segment);
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Isolated BKGDB v1.2 storage-core tests: explicit module wiring keeps the
    // canonical codec import independent from the legacy/monolithic build graph.
    {
        const canonical_tlv = b.addModule("canonical_tlv", .{
            .root_source_file = b.path("libs/bkg-db/src/encoding/canonical_tlv.zig"),
            .target = target,
            .optimize = optimize,
        });
        const wal_test = b.addTest(.{
            .name = "bkg-db-storage-wal-v1-2",
            .root_module = b.createModule(.{
                .root_source_file = b.path("libs/bkg-db/src/storage/wal.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        wal_test.root_module.addImport("canonical_tlv.zig", canonical_tlv);
        const run_wal_test = b.addRunArtifact(wal_test);
        storage_wal_test_step.dependOn(&run_wal_test.step);
        test_step.dependOn(&run_wal_test.step);

        const bkg_db_storage_state = b.addModule("bkg-db-storage-state", .{
            .root_source_file = b.path("libs/bkg-db/src/storage/state.zig"),
            .target = target,
            .optimize = optimize,
        });
        bkg_db_storage_state.addImport("canonical_tlv.zig", canonical_tlv);

        const bkg_db_storage_wal = b.addModule("bkg-db-storage-wal", .{
            .root_source_file = b.path("libs/bkg-db/src/storage/wal.zig"),
            .target = target,
            .optimize = optimize,
        });
        bkg_db_storage_wal.addImport("canonical_tlv.zig", canonical_tlv);

        const bkg_db_storage_core = b.addModule("bkg-db-storage-core", .{
            .root_source_file = b.path("libs/bkg-db/src/storage/core.zig"),
            .target = target,
            .optimize = optimize,
        });
        bkg_db_storage_core.addImport("canonical_tlv.zig", canonical_tlv);
        bkg_db_storage_core.addImport("state.zig", bkg_db_storage_state);
        bkg_db_storage_core.addImport("wal.zig", bkg_db_storage_wal);

        const crash_test = b.addTest(.{
            .name = "bkg-db-storage-crash-invariants-v1-2",
            .root_module = b.createModule(.{
                .root_source_file = b.path("libs/bkg-db/src/tests/crash_invariants.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        crash_test.root_module.addImport("canonical_tlv.zig", canonical_tlv);
        crash_test.root_module.addImport("wal.zig", bkg_db_storage_wal);
        crash_test.root_module.addImport("state.zig", bkg_db_storage_state);
        crash_test.root_module.addImport("core.zig", bkg_db_storage_core);
        const run_crash_test = b.addRunArtifact(crash_test);
        storage_wal_test_step.dependOn(&run_crash_test.step);
        test_step.dependOn(&run_crash_test.step);
    }
    // bkg-db-crypto-envelope: BKGDB Encryption Envelope v1
    // Eigenständiger Test-Root ohne externe Modul-Imports (nur std).
    const bkg_db_crypto_envelope_mod = b.addModule("bkg-db-crypto-envelope-mod", .{
        .root_source_file = b.path("libs/bkg-db/src/crypto/envelope.zig"),
    });
    {
        const t = b.addTest(.{
            .name = "bkg-db-crypto-envelope",
            .root_module = b.createModule(.{
                .root_source_file = b.path("libs/bkg-db/src/crypto/envelope.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run = b.addRunArtifact(t);
        crypto_envelope_step.dependOn(&run.step);
        test_step.dependOn(&run.step);
    }
    // bkg-db-crypto-keyring: BKGDB Keyring v1
    // Importiert envelope.zig als Modul (Consumer, kein Patch).
    {
        const t = b.addTest(.{
            .name = "bkg-db-crypto-keyring",
            .root_module = b.createModule(.{
                .root_source_file = b.path("libs/bkg-db/src/crypto/keyring.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        t.root_module.addImport("envelope.zig", bkg_db_crypto_envelope_mod);
        const run = b.addRunArtifact(t);
        const keyring_step = b.step("bkg-db-crypto-keyring", "Run BKGDB Keyring v1 tests");
        keyring_step.dependOn(&run.step);
        test_step.dependOn(&run.step);
    }
    // bkg-db-crypto-keyring-mod: Keyring als Modul für WAL-Encryption-Consumer
    const bkg_db_crypto_keyring_mod = b.addModule("bkg-db-crypto-keyring-mod", .{
        .root_source_file = b.path("libs/bkg-db/src/crypto/keyring.zig"),
    });
    bkg_db_crypto_keyring_mod.addImport("envelope.zig", bkg_db_crypto_envelope_mod);

    // bkg-db-wal-encryption: WAL Encryption v1 Consumer Layer
    {
        const t = b.addTest(.{
            .name = "bkg-db-wal-encryption",
            .root_module = b.createModule(.{
                .root_source_file = b.path("libs/bkg-db/src/engine/wal_encryption.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        // ledger_wal.zig importiert seinerseits protocol/*.zig — diese werden
        // über das bestehende Modul-System aufgelöst, da wal_encryption als
        // eigenständige Test-Root läuft und ledger_wal intern @import nutzt.
        t.root_module.addImport("ledger_wal.zig",          b.addModule("bkg-db-ledger-wal-for-enc", .{
            .root_source_file = b.path("libs/bkg-db/src/engine/ledger_wal.zig"),
        }));
        // ledger_wal.zig braucht protocol-Module
        const ledger_wal_for_enc = t.root_module.import_table.get("ledger_wal.zig").?;
        ledger_wal_for_enc.addImport("../protocol/ledger.zig",  bkg_db_proto_ledger);
        ledger_wal_for_enc.addImport("../protocol/state.zig",   bkg_db_proto_state);
        ledger_wal_for_enc.addImport("../protocol/events.zig",  bkg_db_proto_events);
        t.root_module.addImport("../crypto/envelope.zig", bkg_db_crypto_envelope_mod);
        t.root_module.addImport("../crypto/keyring.zig",  bkg_db_crypto_keyring_mod);
        const run = b.addRunArtifact(t);
        const wal_enc_step = b.step("bkg-db-wal-encryption", "Run BKGDB WAL Encryption v1 tests");
        wal_enc_step.dependOn(&run.step);
        test_step.dependOn(&run.step);
    }
    // bkg-db-wal-encryption-e2e: WAL Encryption v1 Storage Consumer Layer
    // storage/wal_encrypted.zig — vollständige API mit Replay-Beweis-Test
    {
        const t = b.addTest(.{
            .name = "bkg-db-wal-encryption-e2e",
            .root_module = b.createModule(.{
                .root_source_file = b.path("libs/bkg-db/src/storage/wal_encrypted.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const ledger_wal_for_e2e = b.addModule("bkg-db-ledger-wal-for-e2e", .{
            .root_source_file = b.path("libs/bkg-db/src/engine/ledger_wal.zig"),
        });
        ledger_wal_for_e2e.addImport("../protocol/ledger.zig",  bkg_db_proto_ledger);
        ledger_wal_for_e2e.addImport("../protocol/state.zig",   bkg_db_proto_state);
        ledger_wal_for_e2e.addImport("../protocol/events.zig",  bkg_db_proto_events);
        t.root_module.addImport("ledger_wal.zig",         ledger_wal_for_e2e);
        t.root_module.addImport("../crypto/envelope.zig", bkg_db_crypto_envelope_mod);
        t.root_module.addImport("../crypto/keyring.zig",  bkg_db_crypto_keyring_mod);
        const run = b.addRunArtifact(t);
        const e2e_step = b.step("bkg-db-wal-encryption-e2e", "Run BKGDB WAL Encryption v1 E2E tests");
        e2e_step.dependOn(&run.step);
        test_step.dependOn(&run.step);
    }
    // ── bkg-model: BKG Model Layer v1 ────────────────────────────────────────
    // Module-Graph (keine Zyklen):
    //   hash → artifact → manifest → lineage → capability →
    //   knowledge_snapshot → validator → materializer → diversity → evolution
    //
    // Import-Schlüssel = exakter @import()-String in der Quelldatei.
    const bkg_model_hash = b.addModule("bkg-model-hash", .{
        .root_source_file = b.path("libs/bkg-model/src/hash.zig"),
    });
    const bkg_model_artifact = b.addModule("bkg-model-artifact", .{
        .root_source_file = b.path("libs/bkg-model/src/artifact.zig"),
    });
    bkg_model_artifact.addImport("hash.zig", bkg_model_hash);

    const bkg_model_manifest = b.addModule("bkg-model-manifest", .{
        .root_source_file = b.path("libs/bkg-model/src/manifest.zig"),
    });
    bkg_model_manifest.addImport("hash.zig",     bkg_model_hash);
    bkg_model_manifest.addImport("artifact.zig", bkg_model_artifact);

    const bkg_model_lineage = b.addModule("bkg-model-lineage", .{
        .root_source_file = b.path("libs/bkg-model/src/lineage.zig"),
    });
    bkg_model_lineage.addImport("hash.zig",     bkg_model_hash);
    bkg_model_lineage.addImport("artifact.zig", bkg_model_artifact);

    const bkg_model_capability = b.addModule("bkg-model-capability", .{
        .root_source_file = b.path("libs/bkg-model/src/capability.zig"),
    });
    bkg_model_capability.addImport("hash.zig",     bkg_model_hash);
    bkg_model_capability.addImport("artifact.zig", bkg_model_artifact);

    const bkg_model_snapshot = b.addModule("bkg-model-snapshot", .{
        .root_source_file = b.path("libs/bkg-model/src/knowledge_snapshot.zig"),
    });
    bkg_model_snapshot.addImport("hash.zig",     bkg_model_hash);
    bkg_model_snapshot.addImport("artifact.zig", bkg_model_artifact);

    const bkg_model_validator = b.addModule("bkg-model-validator", .{
        .root_source_file = b.path("libs/bkg-model/src/validator.zig"),
    });
    bkg_model_validator.addImport("hash.zig",     bkg_model_hash);
    bkg_model_validator.addImport("artifact.zig", bkg_model_artifact);
    bkg_model_validator.addImport("manifest.zig", bkg_model_manifest);
    bkg_model_validator.addImport("lineage.zig",  bkg_model_lineage);

    const bkg_model_materializer = b.addModule("bkg-model-materializer", .{
        .root_source_file = b.path("libs/bkg-model/src/materializer.zig"),
    });
    bkg_model_materializer.addImport("hash.zig",        bkg_model_hash);
    bkg_model_materializer.addImport("artifact.zig",    bkg_model_artifact);
    bkg_model_materializer.addImport("capability.zig",  bkg_model_capability);
    bkg_model_materializer.addImport("validator.zig",   bkg_model_validator);
    bkg_model_materializer.addImport("lineage.zig",     bkg_model_lineage);
    bkg_model_materializer.addImport("manifest.zig",    bkg_model_manifest);

    const bkg_model_diversity = b.addModule("bkg-model-diversity", .{
        .root_source_file = b.path("libs/bkg-model/src/diversity.zig"),
    });
    bkg_model_diversity.addImport("hash.zig", bkg_model_hash);

    const bkg_model_evolution = b.addModule("bkg-model-evolution", .{
        .root_source_file = b.path("libs/bkg-model/src/evolution.zig"),
    });
    bkg_model_evolution.addImport("hash.zig",      bkg_model_hash);
    bkg_model_evolution.addImport("diversity.zig", bkg_model_diversity);

    // Separater Test-Step für Model Layer
    const model_layer_step = b.step("bkg-model", "Run BKG Model Layer v1 tests");

    // Test-Targets pro Modul (standalone, mit expliziten Imports)
    {
        const t = b.addTest(.{ .name = "bkg-model-hash", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-model/src/hash.zig"),
            .target = target, .optimize = optimize,
        })});
        const run = b.addRunArtifact(t);
        model_layer_step.dependOn(&run.step);
        test_step.dependOn(&run.step);
    }
    {
        const t = b.addTest(.{ .name = "bkg-model-artifact", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-model/src/artifact.zig"),
            .target = target, .optimize = optimize,
        })});
        t.root_module.addImport("hash.zig", bkg_model_hash);
        const run = b.addRunArtifact(t);
        model_layer_step.dependOn(&run.step);
        test_step.dependOn(&run.step);
    }
    {
        const t = b.addTest(.{ .name = "bkg-model-manifest", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-model/src/manifest.zig"),
            .target = target, .optimize = optimize,
        })});
        t.root_module.addImport("hash.zig",     bkg_model_hash);
        t.root_module.addImport("artifact.zig", bkg_model_artifact);
        const run = b.addRunArtifact(t);
        model_layer_step.dependOn(&run.step);
        test_step.dependOn(&run.step);
    }
    {
        const t = b.addTest(.{ .name = "bkg-model-lineage", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-model/src/lineage.zig"),
            .target = target, .optimize = optimize,
        })});
        t.root_module.addImport("hash.zig",     bkg_model_hash);
        t.root_module.addImport("artifact.zig", bkg_model_artifact);
        const run = b.addRunArtifact(t);
        model_layer_step.dependOn(&run.step);
        test_step.dependOn(&run.step);
    }
    {
        const t = b.addTest(.{ .name = "bkg-model-capability", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-model/src/capability.zig"),
            .target = target, .optimize = optimize,
        })});
        t.root_module.addImport("hash.zig",     bkg_model_hash);
        t.root_module.addImport("artifact.zig", bkg_model_artifact);
        const run = b.addRunArtifact(t);
        model_layer_step.dependOn(&run.step);
        test_step.dependOn(&run.step);
    }
    {
        const t = b.addTest(.{ .name = "bkg-model-snapshot", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-model/src/knowledge_snapshot.zig"),
            .target = target, .optimize = optimize,
        })});
        t.root_module.addImport("hash.zig",     bkg_model_hash);
        t.root_module.addImport("artifact.zig", bkg_model_artifact);
        const run = b.addRunArtifact(t);
        model_layer_step.dependOn(&run.step);
        test_step.dependOn(&run.step);
    }
    {
        const t = b.addTest(.{ .name = "bkg-model-validator", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-model/src/validator.zig"),
            .target = target, .optimize = optimize,
        })});
        t.root_module.addImport("hash.zig",     bkg_model_hash);
        t.root_module.addImport("artifact.zig", bkg_model_artifact);
        t.root_module.addImport("manifest.zig", bkg_model_manifest);
        t.root_module.addImport("lineage.zig",  bkg_model_lineage);
        const run = b.addRunArtifact(t);
        model_layer_step.dependOn(&run.step);
        test_step.dependOn(&run.step);
    }
    {
        const t = b.addTest(.{ .name = "bkg-model-materializer", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-model/src/materializer.zig"),
            .target = target, .optimize = optimize,
        })});
        t.root_module.addImport("hash.zig",       bkg_model_hash);
        t.root_module.addImport("artifact.zig",   bkg_model_artifact);
        t.root_module.addImport("capability.zig", bkg_model_capability);
        t.root_module.addImport("validator.zig",  bkg_model_validator);
        t.root_module.addImport("lineage.zig",    bkg_model_lineage);
        t.root_module.addImport("manifest.zig",   bkg_model_manifest);
        const run = b.addRunArtifact(t);
        model_layer_step.dependOn(&run.step);
        test_step.dependOn(&run.step);
    }
    {
        const t = b.addTest(.{ .name = "bkg-model-diversity", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-model/src/diversity.zig"),
            .target = target, .optimize = optimize,
        })});
        t.root_module.addImport("hash.zig", bkg_model_hash);
        const run = b.addRunArtifact(t);
        model_layer_step.dependOn(&run.step);
        test_step.dependOn(&run.step);
    }
    {
        const t = b.addTest(.{ .name = "bkg-model-evolution", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-model/src/evolution.zig"),
            .target = target, .optimize = optimize,
        })});
        t.root_module.addImport("hash.zig",      bkg_model_hash);
        t.root_module.addImport("diversity.zig", bkg_model_diversity);
        const run = b.addRunArtifact(t);
        model_layer_step.dependOn(&run.step);
        test_step.dependOn(&run.step);
    }

    const bkg_exe_mod = b.createModule(.{
        .root_source_file = b.path("utils/bkg/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    bkg_exe_mod.addImport("bkg-core", bkg_core);
    bkg_exe_mod.addImport("bkg-vault", bkg_vault);
    bkg_exe_mod.addImport("bkg-auth", bkg_auth);
    bkg_exe_mod.addImport("bkg-web", bkg_web);
    bkg_exe_mod.addImport("bkg-db", bkg_db);
    bkg_exe_mod.addImport("bkg-cli", bkg_cli);
    bkg_exe_mod.addImport("bkg-config", bkg_config);
    const exe = b.addExecutable(.{
        .name = "bkg",
        .root_module = bkg_exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the bkg CLI");
    run_step.dependOn(&run_cmd.step);

    // ── BKGDB Evolution Memory — Stage 1 ────────────────────────────────────
    // Neue Dateien: libs/bkg-db/src/evolution/artifact_store.zig
    //               libs/bkg-db/src/evolution/spore_store.zig
    // Keine externen Imports — nur std.
    {
        const t = b.addTest(.{ .name = "bkg-db-evolution-artifact-store", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-db/src/evolution/artifact_store.zig"),
            .target = target, .optimize = optimize,
        })});
        const run = b.addRunArtifact(t);
        test_step.dependOn(&run.step);
    }
    {
        const t = b.addTest(.{ .name = "bkg-db-evolution-spore-store", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-db/src/evolution/spore_store.zig"),
            .target = target, .optimize = optimize,
        })});
        const run = b.addRunArtifact(t);
        test_step.dependOn(&run.step);
    }
    {
        const t = b.addTest(.{ .name = "bkg-db-evolution-lineage-index", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-db/src/evolution/lineage_index.zig"),
            .target = target, .optimize = optimize,
        })});
        const run = b.addRunArtifact(t);
        test_step.dependOn(&run.step);
    }
    // ── BKGDB Evolution Memory — Stage 3 ────────────────────────────────────
    // forge_knowledge.zig — Forge Knowledge Dimension (keine externen Imports)
    const forge_knowledge_step = b.step("bkg-db-evolution-forge-knowledge", "Run BKGDB Forge Knowledge Stage 3 tests");
    {
        const t = b.addTest(.{ .name = "bkg-db-evolution-forge-knowledge", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-db/src/evolution/forge_knowledge.zig"),
            .target = target, .optimize = optimize,
        })});
        const run = b.addRunArtifact(t);
        forge_knowledge_step.dependOn(&run.step);
        test_step.dependOn(&run.step);
    }
    // ── BKGDB Evolution Memory — Stage 4 ────────────────────────────────────
    // agent_lineage.zig — Agent Lineage Projection (keine externen Imports)
    const agent_lineage_step = b.step("bkg-db-evolution-agent-lineage", "Run BKGDB Agent Lineage Stage 4 tests");
    {
        const t = b.addTest(.{ .name = "bkg-db-evolution-agent-lineage", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-db/src/evolution/agent_lineage.zig"),
            .target = target, .optimize = optimize,
        })});
        const run = b.addRunArtifact(t);
        agent_lineage_step.dependOn(&run.step);
        test_step.dependOn(&run.step);
    }
    // ── BKGDB Evolution Memory — Stage 5 ────────────────────────────────────
    // evidence_store.zig — Evidence Store (keine externen Imports)
    const evidence_store_step = b.step("bkg-db-evolution-evidence-store", "Run BKGDB Evidence Store Stage 5 tests");
    {
        const t = b.addTest(.{ .name = "bkg-db-evolution-evidence-store", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-db/src/evolution/evidence_store.zig"),
            .target = target, .optimize = optimize,
        })});
        const run = b.addRunArtifact(t);
        evidence_store_step.dependOn(&run.step);
        test_step.dependOn(&run.step);
    }
    // ── BKGDB Evolution Memory — Stage 6 ────────────────────────────────────
    // asset_state.zig — Asset State Projection (keine externen Imports)
    const asset_state_step = b.step("bkg-db-evolution-asset-state", "Run BKGDB Asset State Stage 6 tests");
    {
        const t = b.addTest(.{ .name = "bkg-db-evolution-asset-state", .root_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-db/src/evolution/asset_state.zig"),
            .target = target, .optimize = optimize,
        })});
        const run = b.addRunArtifact(t);
        asset_state_step.dependOn(&run.step);
        test_step.dependOn(&run.step);
    }
    // ── BKGDB Evolution Memory — Stage 7 ────────────────────────────────────
    // artifact_source_adapter.zig — ArtifactSource Adapter (importiert artifact_store + Model Layer)
    const artifact_source_adapter_step = b.step("bkg-db-evolution-artifact-source-adapter", "Run BKGDB ArtifactSource Adapter Stage 7 tests");
    {
        const adapter_module = b.createModule(.{
            .root_source_file = b.path("libs/bkg-db/src/evolution/artifact_source_adapter.zig"),
            .target = target, .optimize = optimize,
        });
        adapter_module.addImport("artifact_store.zig", b.createModule(.{
            .root_source_file = b.path("libs/bkg-db/src/evolution/artifact_store.zig"),
            .target = target, .optimize = optimize,
        }));
        adapter_module.addImport("manifest.zig",  bkg_model_manifest);
        adapter_module.addImport("artifact.zig",  bkg_model_artifact);
        adapter_module.addImport("hash.zig",      bkg_model_hash);
        adapter_module.addImport("validator.zig", bkg_model_validator);
        const t = b.addTest(.{ .name = "bkg-db-evolution-artifact-source-adapter", .root_module = adapter_module });
        const run = b.addRunArtifact(t);
        artifact_source_adapter_step.dependOn(&run.step);
        test_step.dependOn(&run.step);
    }
}
