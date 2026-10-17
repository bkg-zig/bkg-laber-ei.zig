# BKG Zig architecture

## Layer order

The supported dependency direction is:

```text
zig.vanilla → banana.bkg → zig-body.bkg → zig-app.bkg
```

Each layer has a distinct responsibility:

- **`zig.vanilla`** is the upstream Zig reference. Keep BKG patches and product
  code out of it.
- **`banana.bkg`** contains BKG-specific compiler or language changes. It is
  not a home for framework libraries or product features.
- **`zig-body.bkg`** contains shared framework functionality and reusable
  libraries.
- **`zig-app.bkg`** contains product applications. The BKG-TTS application is
  located in the workspace-root `bkg-tts.zig/` directory.

Dependencies may point only toward lower layers. Avoid reverse dependencies,
layer bypasses, and direct use of upstream internals in place of documented
framework APIs.

## Implementation boundaries

- Put a change in the lowest layer that owns its responsibility.
- Reuse a framework module only after its behavior and tests establish that it
  meets the application's needs.
- Keep application-specific composition in the app layer.
- Use TypeScript only at boundaries that require the VS Code Extension API;
  keep the BKG core in native Zig.
- Preserve existing extension behavior until a replacement and its migration
  have been verified.
