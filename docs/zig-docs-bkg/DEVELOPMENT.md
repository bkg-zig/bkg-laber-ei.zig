# Development and verification

## Before changing code

1. Read the repository's agent instructions, project plan, and relevant
   framework and application documentation.
2. Check the working tree and identify existing changes before editing.
3. Identify the owning layer and inspect the APIs already available there.
4. Claim the task in the shared coordination board, with a bounded scope,
   target files, dependencies, and acceptance criteria.

If a required architecture rule or dependency contract is unavailable, record
the blocker and do not invent a replacement rule.

## Layer gates

For a change that spans layers, work from the lowest affected layer upward:

```text
change → test → build → proceed to the next layer
```

Repair failures at their owning layer. Do not hide a missing lower-layer
capability with a higher-layer workaround.

## Branches, reviews, and handoffs

- Make changes on a task-specific branch and submit them through a pull request.
- Do not commit or push directly to `main`.
- Keep each change scoped; coordinate before editing files owned by another
  active task.
- Record commands actually run, results, known failures, and remaining work.
- A review must inspect the actual diff and evidence. Do not report a review,
  test, build, or platform as successful unless it was actually completed.

## Completion

A task is complete only when its acceptance criteria and relevant checks pass
and the documentation and coordination status reflect the verified result.
Label unavailable checks as not run, and document genuine blockers with the
smallest concrete next step.
