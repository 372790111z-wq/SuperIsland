# AI Usage Rings Extension

Displays Codex + Claude usage/availability inside SuperIsland with circular indicators.

## Colors

- Green: healthy/available
- Orange: low
- Red: very low / blocked

## Permissions

- `usage` (required for `SuperIsland.system.getAIUsage()`)

## Data Sources

- Codex:
  - `~/.codex/usage-summary.json` or `~/.codex/usage/summary.json`
  - fallback: ChatGPT OAuth usage API (`https://chatgpt.com/backend-api/wham/usage`) using token from `~/.codex/auth.json`
  - Local summaries must include `accountId` (or `account_id`) matching the current Codex account, a recent `updatedAt` Unix timestamp, and valid numeric window fields. Otherwise SuperIsland uses the API; it never writes these files or refreshes login credentials.
- Claude:
  - `~/.claude/usage-summary.json` or `~/.config/claude/usage-summary.json`
  - fallback: Anthropic OAuth usage API (`https://api.anthropic.com/api/oauth/usage`) using token from:
    - `~/.claude/.credentials.json` / `~/.claude/credentials.json`
    - macOS keychain service `Claude Code-credentials`
  - last fallback: `~/.claude/stats-cache.json`
- SuperIsland first checks the Claude keychain item without showing UI. If macOS
  requires a password prompt, SuperIsland only asks once and then falls back to
  local Claude usage/cache data unless the keychain item can be read silently.

## Refresh Behavior

- Codex and Claude refresh independently. A slow Claude request cannot delay a Codex result.
- Codex normally refreshes every 5 minutes while the extension is visible. Requests run in the background with a 10-second limit; timed-out tasks are cancelled and late responses cannot overwrite newer state.
- A temporary Codex failure retries after 15, 30, then 60 seconds (driven by the visible extension refresh). Rate limits respect `Retry-After`, capped at 5 minutes; authentication failures wait 5 minutes or until credentials change.
- During a temporary failure, the last successful Codex reading stays visible for at most 15 minutes, with “更新延迟” and its original update time. Authentication failure, sign-out, account change, or expiry clears the reading. No-data is never interpreted as 0% usage or unlimited quota.
- Only actual Codex windows are shown. A weekly-only response does not create a session allowance.
- Codex refresh completion updates the active extension; one render pass uses the same snapshot for all display sizes. Logs contain fixed success/error categories, never credentials, account identifiers, or response bodies.
- Claude retains its existing 5-minute cache and collection behavior.
- Claude reads session (`five_hour`) and weekly (`seven_day*`) windows from OAuth usage when available.
- Week/session values no longer mirror overall remaining when source data is missing (they show `--%`).
