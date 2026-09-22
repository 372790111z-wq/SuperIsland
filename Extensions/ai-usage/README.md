# AI Usage Rings Extension

Displays Codex + Claude usage/availability inside SuperIsland with circular indicators.

## 使用与常见情况

- 在“设置 → 扩展”选择“AI 用量环”，确认扩展已启用，再在灵动岛中查看该模块的读数。设置页的“活动中”只表示扩展在运行，不保证数据源已返回额度。
- Codex 使用本机现有登录状态或匹配当前账号的用量摘要；不用在 SuperIsland 中粘贴令牌。认证失效时，到 Codex 完成登录后再查看。
- 本机未安装或未配置 Claude 时，没有 Claude 数据是正常情况，不影响 Codex 独立刷新；Claude 功能仍保留。
- “更新延迟”表示暂时显示上次成功读取的数据，完整视图会注明原更新时间。它不是实时读数，最多保留 15 分钟。
- `--` 表示当前没有可用数据，不表示已经用完，也不表示无限额度。只有周额度的数据源不会额外显示一个会话额度。
- 扩展界面更新与服务器请求频率不同：Codex 正常缓存 5 分钟，网络失败按下述规则重试。重新查看模块不一定立即发送新的服务器请求。

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
