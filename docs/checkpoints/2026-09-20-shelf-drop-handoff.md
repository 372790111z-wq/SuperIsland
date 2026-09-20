# Shelf drag handoff repair — 2026-09-20

## Baseline and scope

- Worktree: `we1-file-shortcuts`; branch: `fix/we1-shelf-drop-handoff-20260920`.
- Parent: `3c47670`; retained installed baseline: `we1-165341-restored-settings-installed-20260920` (build `20260920165341`).
- User reports Finder/desktop files reveal the AirDrop/tray areas, but releasing does nothing; Mission Control also appears.
- Existing Shelf requirements remain in `docs/SHELF.md`. This repairs delivery of that behavior; no new page, setting, or annotation schema.

## Evidence and change

The outer drop target previously owned the only drag hold. Its exit scheduled release after 350 ms, while the inner AirDrop/tray targets only updated their visual highlight. Thus a child could remain targeted after the parent had released the hold.

All three destinations now use the same delegate and AppState-owned set of destination IDs. Entering any destination keeps the presentation open; delayed exit checks a generation before releasing it. IDs distinguish separate views/displays. Drop completion clears overlapping destinations; disappearance and disable remove their own destination. The drop proposal is copy, preserving the original Finder file. AirDrop and tray retain their separate receiver actions.

Diagnostic events record destination, enter/exit/drop, provider count, supported categories and extracted/added counts. They no longer record filenames, paths, URLs, or file content.

This fixes a demonstrated code gap. The actual failing native event sequence has not yet been captured, so this is not a claim that the entire reported failure has been reproduced and resolved.

## Verification

- 30 focused XCTest cases passed, including 7 new destination-lifetime tests and 6 new real NSItemProvider tests, plus existing window-drag hover and Zilan suppression tests.
- Provider fixtures cover NSURL file URL, file-url Data with Unicode/spaces, folders, multiple files, failed payload, and retaining valid files when another provider fails.
- Tests use their own temporary files; they do not use ShelfStore.shared, send AirDrop, or modify the user's staged files/settings.
- Artifact: `build/WE1ShelfDrop.noindex/ShelfDropFinalTests.xcresult`; full compiler log: `tests-final.log` in the same directory.
- Independent source review found no blocking issue. The selected native destination, cancellation delivery, and actual Finder gesture still require desktop verification.

## Mission Control evidence boundary

Source audit found no direct Mission Control launch call in this path. The observed `session recovered from pointer root probe` entries alone do not prove a real Mission Control launch; unresolved hits clear the close overlay. This patch does not change Mission Control, hot corners, Dock/Cmd-Tab, snap geometry, or extension settings.

## Native acceptance still required

1. Drag a disposable Finder file to the tray: one item appears, original remains.
2. Drag a disposable file to AirDrop: verify its sharing panel, then cancel without sending.
3. Move between outer surface and both panes, cancel with Esc, and drag in again.
4. Check whether real Mission Control still appears; correlate only sanitized destination events.

No desktop gestures or app replacement were performed during source diagnosis and tests. Keep build 165341 running until the candidate is explicitly installed. This checkpoint and tests are local; no GitHub push or release is implied.
