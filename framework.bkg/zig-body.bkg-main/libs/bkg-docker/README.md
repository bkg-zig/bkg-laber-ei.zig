# bkg-docker

Wiederverwendbare Zig-Library für Docker-Kommunikation über Unix-Domain-Socket.

## Inhalt

| Datei | Beschreibung |
|-------|-------------|
| `src/bkg_docker.zig` | Root-Modul, re-exportiert client, stream, demux |
| `src/client.zig` | HTTP-Client über `/var/run/docker.sock` (Zig 0.16 `std.Io.net`) |
| `src/stream.zig` | Zeilenweiser Callback-Parser für Docker Event/Log Streams |
| `src/demux.zig` | Docker Multiplexed Stream Decoder (8-Byte-Frame-Header) |

## Verwendung

```zig
const bkg_docker = @import("bkg-docker");

// HTTP-Request
const client = bkg_docker.client.Client.init(allocator, "/var/run/docker.sock");
const resp = try client.get(io, "/containers/json?all=1");
defer resp.deinit();

// Demux (Logs)
const stdout = try bkg_docker.demux.demux(allocator, raw_log_body);
defer allocator.free(stdout);

// Stream zeilenweise
bkg_docker.stream.eachLine(body, ctx, callback);
```

## Zig-Version

Setzt Zig 0.16 voraus (`std.Io.net.UnixAddress.connect(io)`, `std.ArrayList(u8).empty`).
