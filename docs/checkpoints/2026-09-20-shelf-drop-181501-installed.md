# Shelf drop build 181501 installed — 2026-09-20

- User explicitly confirmed installing candidate 181501 and restarting only WE1.
- Code source: `b59ed2adeeb41c78dea45218037da03300622d08`; prior source/verification record: `2026-09-20-shelf-drop-handoff.md`.
- Installed path: `/Applications/SuperIsland-WE1-Debug.app`.
- Installed build: `20260920181501`; version 1.0.9, optimized, approximately 20.16 MB.
- Old process 39204 exited normally. New PID `85107` launched from the installed path and remained running on subsequent readback.
- Installed executable SHA-256: `a20ab536badac537708a209e0a5def2072e0d09c149bdef9981ada59010df7fe`.
- Deep/strict signature verification passed, using the same WE1 bundle ID and designated requirement as 165341.
- All resource hashes, six bundled extensions, and entitlements match the prior installed bundle. No test bundle or debug dylib ships.

## Rollback

The intact previous 165341 bundle is retained at:

`/Users/muyz/Projects/new super island/worktrees/we1-file-shortcuts/build/WE1ShelfDrop.noindex/Rollback/SuperIsland-WE1-Debug-20260920165341.app`

Its executable SHA-256 remains `527df97ad2cd0a02c8b2b1ca6d58043111cccd45e4cea35f9c6d0b8333e28671`. To roll back, quit only WE1 normally, preserve the current bundle separately, restore this bundle to the same installed path, verify its signature, then reopen. No cache or preference reset is required by this rollback.

## Verification boundary

The prior 30 focused XCTest cases and Release build passed. This turn verified installation, signing, bundle provenance, backup, and running process. No mouse movement, window switching, Finder drag, AirDrop transmission, or user-file deletion was performed. Actual tray reception, sharing-panel appearance, and the reported Mission Control trigger remain pending native user verification.

Local installation manifest: `build/WE1ShelfDrop.noindex/installation.json`. No GitHub push or release was performed.
