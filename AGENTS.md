# Agent Onboarding

This file is the repository-wide entry point for every human and AI agent working in this repository. Read it before inspecting deeply, planning, editing, reviewing, or running tasks.

## Mandatory first reads

1. `docs/team/COORDINATION.md` — task ownership, shared status, handoffs, conflict prevention, and decisions.
2. `docs/BKG-TTS-MILESTONES.md` — product plan and milestone acceptance criteria.
3. `docs/BKG-ZIG-AUTHORITY-AND-LAYERS.md` — authoritative rule path and the already-stated layer contract.
4. The relevant project/framework documentation and build manifests before proposing code changes.

The canonical BKG Zig rules are on the BKG system at `/srv/bkg/playground/zig-docs-bkg`. Do not claim to have read that local directory unless you actually had access and inspected it. If it is unreachable, record the blocker in the coordination log and do not guess at missing rules.

## Non-negotiable architecture

Layer order: `zig.vanilla → banana.bkg → zig-body.bkg → zig-app.bkg`.

- `zig.vanilla`: upstream Zig reference only; never put BKG patches or product code here.
- `banana.bkg`: BKG-specific compiler/language fork changes only; never put TTS product code here.
- `zig-body.bkg`: shared BKG framework and reusable APIs.
- `zig-app.bkg`: product applications. The new app belongs in root `bkg-tts.zig/`.
- Dependencies may point only down the documented layer chain. No layer bypasses or reverse dependencies.
- Preserve existing `.bkgtts/` behavior until replacement is implemented and verified.
- Native Zig for the BKG core. TypeScript is limited to boundaries that require the VS Code Extension API.
- No fake events, stubs presented as implementation, copied vendor code, or unverified success claims.

## Coordination is required, not optional

Before starting work, claim one task in `docs/team/COORDINATION.md`. Give it an owner, bounded scope, target files, branch/PR, dependencies, and acceptance criteria. Read the current file first and update it through the same PR as the work when possible.

Do not edit a file or architectural surface already owned by another active task without coordinating a handoff. Split tasks by explicit files/interfaces and avoid parallel changes to the same file. If scope overlaps, stop the overlapping edits and agree on one owner.

Every meaningful change goes on its own branch and through a PR. Never commit or push directly to `main`. One milestone = one branch = one squash PR. Do not start implementation before the two independent M0 reviews are recorded as completed with evidence.

Before handing work off, record changed paths, decisions, commands actually run, results, known failures, and next action. Reviewers must check the actual diff and evidence, not rely on the author's summary.

## Done means verified

A task is done only when its acceptance criteria are met, the relevant checks were actually run, the result is recorded, and documentation/status is updated. Mark unrun checks as NOT RUN; never infer success from a green unrelated CI job. If blocked, record the exact blocker and the smallest next step. Do not silently change architecture rules or rewrite another agent's decisions.
