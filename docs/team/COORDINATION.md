# Agent Coordination Board

This directory is the shared coordination point for all agents. It exists to prevent duplicated work, conflicting edits, and architecture drift. The board is the source of truth for task ownership and handoffs; chat messages alone are not a durable assignment.

## Operating protocol

1. Read root `AGENTS.md` and this file before beginning work.
2. Search the active task table for an existing owner or overlapping scope.
3. Claim one bounded task before editing. Include the task ID, owner/agent identity, objective, exact target paths, branch/PR, dependencies, acceptance criteria, and status.
4. If another active task owns the same paths or interface, do not start parallel edits. Agree on a handoff or split the work by explicit file boundaries first.
5. Update the board when scope, status, dependencies, or findings change. Keep updates in the task's PR when feasible; if the PR is not yet open, make the coordination update on the same work branch.
6. At handoff, record commit/PR, changed paths, tests actually run and their results, unresolved issues, and the next owner/action.
7. A reviewer is not the implementer. Independent reviews must be performed independently and recorded with concrete evidence.
8. Before merge, check for duplicate implementations, stale plans, changed interfaces, unowned files, conflicting assumptions, and drift from the frozen BKG layer rules.

## Task status vocabulary

- `AVAILABLE`: no owner; safe to claim.
- `CLAIMED`: owner and bounded scope recorded; work not yet complete.
- `IN_PROGRESS`: work started on the named branch.
- `BLOCKED`: work cannot proceed; exact blocker and unblock action required.
- `REVIEW`: implementation complete; awaiting independent review.
- `DONE`: acceptance criteria and required checks verified, with evidence.
- `DROPPED`: intentionally stopped; reason and replacement/cleanup recorded.

Never mark `DONE` just because code was written or a PR was opened.

## Active task board

| ID | Task / deliverable | Owner | Target paths / boundaries | Branch / PR | Depends on | Status |
|---|---|---|---|---|---|---|
| DOCS-PUBLIC-SANITIZATION | Prepare a redacted public copy of the BKG Zig documentation | Copilot SDK assistant (current session) | `docs/zig-docs-bkg/` only; preserve original `zig-docs.bkg/`; exclude custom license pending review | `docs/sanitized-zig-docs-public`, commit `d4215eb0` / PR not created | User authorization; local source review; Git push credentials | BLOCKED |
| M0-AUDIT | Repository and `.bkgtts/` inventory; inspect build manifests and available framework APIs | UNASSIGNED | Audit/report files under `docs/`; no product implementation | Not created | Access to repo and local canonical rules | AVAILABLE |
| M0-REVIEW-A | Independent review: layers, build, package paths, framework reuse | UNASSIGNED | Review report under `docs/`; no implementation edits | Not created | M0-AUDIT evidence | AVAILABLE |
| M0-REVIEW-B | Independent review: TTS design, harness events, privacy, auth, migration, accessibility | UNASSIGNED | Review report under `docs/`; no implementation edits | Not created | M0-AUDIT evidence | AVAILABLE |

The table is an initial coordination baseline, not evidence that any review has occurred. The two review tasks must have distinct owners and separate findings. Do not start implementation until both reviews are completed and their evidence is linked here.

## Shared decisions and handoff log

Append concise, dated entries. Link the PR/commit and state whether a point is a decision, finding, or unresolved question. Never silently overwrite an earlier decision; add a superseding entry with rationale.

- 2026-10-18 — DECISION: New TTS app location is repository-root `bkg-tts.zig/`; it belongs to `zig-app.bkg`.
- 2026-10-18 — DECISION: Layer order is `zig.vanilla → banana.bkg → zig-body.bkg → zig-app.bkg`; no bypass or reverse dependency.
- 2026-10-18 — RULE: Canonical local rules path is `/srv/bkg/playground/zig-docs-bkg`. The path was provided by the project owner; do not claim its contents were read unless access was actually available.
- 2026-10-18 — STATUS: M0's two independent reviews are still outstanding until separate review evidence is added here.
- 2026-10-17 — STATUS: DOCS-PUBLIC-SANITIZATION claimed on `docs/sanitized-zig-docs-public`. Prepare only redacted copies under `docs/zig-docs-bkg/`; leave `zig-docs.bkg/` untouched and exclude its custom license pending separate review. Publish by PR, not by pushing to `main`.
- 2026-10-17 — BLOCKED: Sanitized public copies and coordination evidence committed locally as `d4215eb0` on `docs/sanitized-zig-docs-public`. Local pattern scan and `git diff --check` passed; original `zig-docs.bkg/` files and custom license were not included. `git push -u origin docs/sanitized-zig-docs-public` failed because Git could not obtain a password (`unable to get password from user`). No remote branch or PR was created and no push to `main` occurred. Next step: authenticate Git for the configured workspace remote, then push this branch and open its PR.
