## 2026-09-14 — tested native click and session cleanup now pass

User accepted installed20260914114254 card switching, system icon-strip disappearance and hover after reentry. These specific blockers are closed. Broader app/window-state/close and separately deferred capture scenarios are not covered by this confirmation. No further installation approval is needed for this already installed version. See native-acceptance.json; earlier pending-retest notes below are historical.

## 2026-09-14 — 20260914114254 installed; waiting for exact interaction result

Installation is authorized and complete. New WE1 PID41649, full manifest/signature, effective native permissions and retained switches verified. Both WeChat main processes17311/17755 and Dock570 remain. User retest is pending for real card switching, disappearance of the system Cmd-Tab icon row and hover after reentry. Do not repeat installation approval or report native acceptance from260 tests/startup alone. Actual185152 recovery is in the named Trash backup; see installation-state.json. Earlier candidate-not-installed notes below are historical.

## 2026-09-14 — native icon strip remains after card click; candidate ready

User has confirmed × appearance, not activation. Latest185152 logs contain images and actionable exact windows; current main WeChat PID3198/Work2555 evidence supersedes the older empty-AX snapshot for this reproduction. The defect is now scoped to native commit/session teardown. Candidate20260914114254 unifies explicit card activation after native exit confirmation and restores/cleans local tracking on failure and input/tap edges;260 tests/build/analyze/signature/source/resources pass. It is not installed. The old185152 installation and identical recovery package remain intact.

Next gate: explicit candidate installation approval, then real native card-click/window-focus/system-strip disappearance/reentry-hover verification for both WeChat owners and ordinary apps. Unknown AX hierarchy remains fail-closed; one-shot recovery or request logs alone are not activation acceptance. Primary-WeChat capture and broader window-state coverage remain separate, historically scoped items. Evidence: parent .codex-audit/wins/2026-09-14/cmdtab-commit-cleanup/README.md. Earlier sections below are historical snapshots.

## 2026-09-11 — shared entries visible; window actions and pixels not accepted

Installed20260911181204 now shows both WeChat entries by user report, but the user reports missing preview/close and clicks. Reproduction confirms a main-window hit-frame lifecycle gap while Work2 exposes only a nonactionable fallback. Candidate20260911185152 repairs frame ownership and adds bounded missing-owner AX refresh; 240 tests, build/Analyze/signature/package verification pass, and it was installed after user confirmation on 2026-09-13 as PID75143. Manifest/signature and native permission recheck pass; functional acceptance remains pending.

Work2 PID555 currently returns successful empty AXWindows, no focused/main window, and no direct child windows; main75262 has canonical WID5964. The persistent Work2 AX absence and primary transparent pixel limitation remain unresolved. Do not enable fallback operations or claim recovery from the retry implementation alone. Current user clarification about which cards lack images remains unanswered. Need main-card hover/close/click and shared cross-owner native acceptance on the newly installed build; the user has been asked to retest hover and card-body click. Recovery package and exact before images: parent .codex-audit/wins/2026-09-11/wechat-shared-interaction/README.md. Earlier sections below describe historical state.

## 2026-09-11 — shared WeChat 20260911181204 installed; native acceptance pending

Build20260911181204 implements the authorized shared WeChat Cmd-Tab display while preserving per-installation Dock previews. Reviewed 238 tests/build/analyze/signature/resources pass. User explicitly confirmed installation; the candidate is installed and running as WE1 PID55518. Full candidate/installed and old/recovery manifests match; native Accessibility/Screen Recording recheck is effective with the prior enhancement switches preserved. Both WeChats retain75262/555, WINS remains absent. Installation is complete; native list/commit acceptance remains pending.

Remaining acceptance is on the real native switcher: both WeChat icons show correctly labelled windows from both known installations; Dock stays separate; selecting the other owner works by arrow/number plus Command release and by click; unselected release stays native; default Command-W does not close a shared first card; stale/nonactionable selections never transfer to another owner. Verify Dock-targeted Escape delivery/list disappearance, rapid new Cmd-Tab/Escape/click cancellation, and minimized/fullscreen exact focus. No runtime timing or feature acceptance follows from the automated checks. The primary-WeChat transparent thumbnail limitation remains separately deferred.

Evidence and rollback: parent .codex-audit/wins/2026-09-11/wechat-cmdtab-shared/README.md. Earlier per-icon-only Cmd-Tab requirements and diagnostic-only authorization below are historical and are superseded by the user's explicit new display rule.

## 2026-09-11 — persistent identity samples captured; mapping unresolved

Build 20260911170348 is installed after explicit user confirmation (17:18 CST, WE1 PID 44743). Its complete manifest/signature, startup, and native permission/settings recheck pass; the old 20260911102000 installation and backups remain recoverable. Both WeChats retain PIDs 75262/555 and WINS is absent. The candidate passed 226 tests/build/analyze/signing. It adds bounded in-app native identity diagnostics because independent probes repeatedly ended before later user operations; it does not resolve the dual-WeChat mapping.

Installation and actual diagnostic capture are complete. The user retest at 17:21:03/15 CST produced two complete seven-record samples: linked/servesTitle unsupported (-25205), title noValue (-25212), no reference, timeout, truncation, missing event or parse error. No further repetition of the same three reads is needed in this state; broader system identity routes and runtime latency remain unverified. The user reports visiting both icons; the log itself has no per-tile identifier and cannot establish that coverage independently. Require correlated sample/scope/names/relation/finished records before interpreting absent links; timeout, missing records, unsupported reference types and truncation remain unknown. Candidate PIDs and scope/depth alone are not a native tile-to-process proof. Keep the one-step interaction and canonical installation separation.

## 2026-09-11 — current candidate acceptance boundary

Build 20260911102000 passed 220 tests, build/analyze/signing and was installed after explicit user confirmation. WE1 startup and native permission recheck passed; the old 20260911021508 app and full-source checkpoint are preserved. The user has now confirmed Mission Control hover × and Command-W close in the instructed single-window retest. Broader reentry/Space/display coverage and general Cmd-Tab close-action acceptance remain open. Current observation established that the MC close shortcut reached a no-target/unobserved-session branch while the system MC root existed; the exact missed-entry/expiry timing remains unproven.

User identified DoubaoWork and Tencent Lemon. Their affected samples had pointer hits but no AX operation objects; later same-window AX recovery and user retest both show hover × restored. The first-entry empty-AX trigger remains unknown, and actual close action/general app coverage are not yet accepted. Do not mark this fully resolved based on button appearance or frame tests alone.

Two-WeChat native Cmd-Tab mapping remains unresolved. Keep canonical installation separation; do not substitute same-name scoring, app order or a new user chooser. Existing v2 associated-AX probes never sampled a visible native switcher; a real visible-tile sample is needed to assess those links. Primary WeChat transparent capture remains deferred separately.

## 2026-09-10 当前：基线保存不等于功能全部验收

本次已授权事项是本地 Git 存档及独立性能 worktree，不包含性能代码实施、应用安装或远端推送。

- 主微信主窗口取图仍失败，用户已要求暂时搁置；WINS 的同类空白现象不等于已找到根因。
- 两套微信在 Cmd-Tab 均无窗口卡：已观察到原生条目仅暴露名称，跨安装路径身份匹配存在歧义。额外实例选择步骤未获接受；WINS 对双微信的可靠归属未完成现场验证。
- 其他缺预览的应用、原始启动窗口退休的连续过程、更多 Space/显示器场景和性能验收仍开放。
- ZCode 关闭后旧预览问题及此前 Chrome 的已确认场景保留其验收结论；这些结论不自动覆盖其他状态。

当前源码证据、保存范围与恢复说明见 [性能优化前基线说明](docs/checkpoints/2026-09-10-preview-performance-baseline.md)。以下各节为历史记录，旧的“当前”状态不覆盖本节。

## 2026-09-10 latest: Cmd-Tab WeChat no-card cause confirmed

The user reports both WeChat entries completely lack cards. A bounded live AX probe and the actual WE1 PID45493 CmdTabPlus stream agree: native WeChat AXButton exposes name-only identity matching two main installations plus their two AppEx processes; distinct bundle paths cannot form a valid identity group, so native-sync retries hide the overlay before capture. This is separate from the deferred primary Dock pixel issue. Background prewarm shares source=commandTab, so earlier inventory alone was not presentation evidence. Other apps with missing previews remain unidentified.

No production repair was made. The candidate explicit-instance chooser for ambiguous native CmdTab selections is awaiting user decision; no implicit cross-installation grouping or guessed tile/PID mapping is authorized. Optional full-attribute/link sampling did not overlap a visible switcher, so availability of additional system links remains unknown. All bounded probes/stream ended; installed WE1 and both WeChats are preserved. Evidence: parent workspace `.codex-audit/wins/2026-09-10/cmd-tab-preview/diagnosis.json` and `diagnosis.md`. Earlier entries below are historical.

## 2026-09-10 acceptance direction update

The user said “暂时先这样，看别的吧。” Primary WeChat main-window capture is deferred, still unresolved and not accepted. Continue with Cmd-Tab Plus native preview and exact-window selection; first check Chrome thumbnail display and Up/Down selection followed by Command release. No close/quit action is part of this first check. WE1 PID45493 remains active, WINS is absent, and current-session commandTab metadata exists; user-visible behavior is awaiting user observation. Existing accepted behavior and source changes remain preserved.

## 2026-09-10 latest: WINS comparison completed, WE1 restored

- User-supplied WINS screenshots reproduce the primary WeChat main-window blank thumbnail; primary image/article windows and secondary WeChat main/article windows have real thumbnails. This failure is not unique to WE1. Underlying cause is still unknown; no signature, privacy-setting or OS root cause is established.
- WINS PID43537 normally terminated via exact-path-validated NSRunningApplication.terminate(); absence verified. Restored installed WE1 build20260910120616 as PID45493, session561592D6-D5E6-4CFE-AC38-EC3C030D77CC. Native master, Dock Preview and Cmd-Tab Plus are on; both permissions effective after Recheck. Settings closed. Main WeChat40956 and Work2555 were preserved.
- Original WE1 PID38234 was absent on return, cause unknown. It was relaunched, so its memory-only retirement ledger did not survive the control. Earlier ZCode acceptance remains scoped historical user evidence, not a new post-restoration acceptance. Single-display Dock pin is currently unfixed after the pause released its previously paused/nonactive request.
- Primary WeChat capture remains unresolved. No business code, app installation, signing, TCC, WeChat data/settings, commit or remote changes. Evidence: parent workspace `.codex-audit/wins/2026-09-10/wechat-main-window-capture/wins-control-state.json` and `diagnosis.md`. Following entries preserve earlier checkpoints and their process IDs.

## 2026-09-10 current: ZCode native acceptance and WeChat capture diagnosis

ZCode closed-preview build **20260910120616** is installed and running as WE1 PID38234 after user confirmation. The 155-test source, installed/backup manifests, signature, startup and permission recheck passed. ZCode was normally restarted (551 -> 38300) after the new WE1 started; its real WID3018 is exact-bound in the new session. The user subsequently confirmed "zcode 好了": the reported ZCode closed-preview issue passes user acceptance. Installation and this scoped check are complete. Main WeChat capture still fails in the user screenshot; this is specifically the primary installation, with dual WeChat in use.

WeChat main-window activation succeeds but its preview does not recover. Main1655 has SharingNone while Work2 main886 has SharingReadOnly; the state difference's origin is still unknown. Safe capture comparisons did not restore content. The user subsequently authorized only a normal primary-WeChat restart: main534 exited and main40956/new mainWID3115 was opened; the user completed login. Work2 remains555/886. The user confirms primary preview still unavailable, corroborated by raw all-zero screenshots and a bounded exact-window stream comparison; trusted renderer3119 also remains uniform. No privacy override was attempted. Original startup-transition and Cmd-Tab acceptance are still open. Current evidence: parent workspace `.codex-audit/wins/2026-09-10/zcode-closed-preview/native-acceptance.json`, `installation-state-20260910120616.json`, `validation.md`, and `wechat-main-window-capture/diagnosis.md`. The old installation is preserved at `/Users/muyz/.Trash/SuperIsland-WE1-Debug-pre-20260910120616.app`. All sections below are historical checkpoints, not the current installation state.

## 2026-09-10 pre-install checkpoint: candidate installation and startup-transition acceptance

The diagnosed WeChat stale-window admission is repaired in candidate 20260910105458 (144 tests, build/Analyze, signing and source review passed). Installation and native acceptance are pending. Run the candidate before the small startup window is exact-bound, then verify its retirement without restarting WE1. Recheck both WeChats, shared Chrome previews, minimized recovery, and fullscreen return with parallel WINS preview excluded. Cmd-Tab acceptance remains paused. See `.codex-audit/wins/2026-09-10/wechat-retired-window/validation.md` in the parent workspace for evidence and rollback.

# Remaining acceptance and delivery gates

Updated: 2026-09-09. Current state is summarized here; older checkpoints are historical in PROGRESS.md.

## Current installation and accepted rollback baseline

- Previous accepted build **20260909151823** fixes the six CGWindowID CFArray description call sites. It preserves existing window classification, identity, cache and interaction policies.
- All 118 Window Enhancement tests passed (including an actual CoreGraphics lookup of a never-shown test-owned window), and the independent non-test build, Analyze and final signed-package verification passed.
- Now installed after explicit confirmation: `/Applications/SuperIsland-WE1-Debug.app` (arm64), build **20260909175743**, implements the user-approved same-installation shared Chrome preview. All 130 current tests, independent non-test build, Analyze, signature/source verification and read-only live grouping passed. Exact-path startup as PID97991 and current effective permission readback passed. Chrome popup/shared-list, tested single-click card activation in both instances, and one disposable blank-window close/card-removal scenario passed by user confirmation. This-build two-WeChat ownership/list/activation regression also passed by user confirmation (“是的，没问题”). This Chrome repair is accepted for the recorded scenarios.
- User explicitly confirmed installation. The earlier `/Applications/SuperIsland-WE1-Debug.app` installation ran build **20260909151823**, PID **5943**; installed payload and signature match the candidate. Settings UI reports both required/current permissions effective. User later requested saving this accepted version: local checkpoint `1f37eaa416f6c22476d35bfe47da0280d1ce2175`; no push occurred.
- Existing WE1 signing identity is valid in the user context. Sandboxed keychain queries cannot see it and sandboxed signature verification can report NOT_TRUSTED; the unsandboxed deep/strict verification passed. Do not recreate the certificate or change trust/TCC based on those sandbox observations.

## Remaining gates

1. Installation/startup and the Ego Lite Dock preview scenario are complete: after WINS was quit, the user confirmed this scenario works. The accepted build is locally archived and committed; do not repeat these approvals.
2. WeChat multi-window completeness passed by user observation on 2026-09-09: 2 actual windows, 2 Dock preview cards, no blank or duplicate cards. Subsequent user feedback passed two-WeChat ownership with no mixing, omissions or duplicates, and single-click activation of the corresponding WeChat window. Chrome popup/shared-list acceptance now passes on the new build; the tested single-click card activations also pass; the disposable Chrome blank-window close scenario now also passes; this-build WeChat ownership/list/activation regression also passes. Preserve this accepted Chrome repair before further state coverage. The historical Docker check remains deferred pending verification of its current relevance.
3. Chrome repair accepted for tested scenarios on installed build **20260909175743 / PID97991**. Installation is already explicitly authorized and complete; do not ask again. The user superseded per-icon instance isolation with “那就同样都显示就行了”. Both same-installation icons resolve all matching processes, each card bound to its own PID/process lifetime/window; different-path WeChat installations remain separate. The new build's native permissions and startup passed, WINS was stopped under the prior explicit quit request and verified absent. The user confirmed both icons pop up with the same complete list (“可以，继续。”). New-build Dock diagnostics enumerate both Chrome member PIDs with one real window each and no rejections in observed samples. The user then confirmed the tested single-click activation in both instances (“可以”). The user then confirmed the tested blank-window close/card-removal scenario (“确认”): only the target closes, other windows remain, and its card disappears on re-hover. The Chrome process/instance for this close was not specified. Both WeChat icons were then confirmed to retain separate ownership, completeness/no duplicates and correct activation on this build (“是的，没问题”). The user subsequently confirmed one minimized Chrome window remains in preview and its card restores/activates correctly (“可以 i”). This post-snapshot test passes for that window; the process/instance was not specified. The user then confirmed one Chrome fullscreen window remains previewable from the regular desktop and clicking its card returns to that exact fullscreen window (“可以，没问题”). The tested fullscreen scenario passes; other Space/display cases remain unverified. Next validation is Cmd-Tab Plus window preview/selection. WeChat close and other system-state coverage remain open. The agent did not modify Chrome processes or browser content; the user performed the disposable-window acceptance check. Evidence is under `/Users/muyz/Projects/new super island/.codex-audit/wins/2026-09-09/chrome-shared-preview/`.
4. Observe residual startup/first-admission gaps only after correcting this confirmed encoding defect. WINS startup enumeration and its Space-related preparation are not implemented by this patch. Do not remove preview-only guards or perform Space mutations without separately establishing the need and safe boundaries.
5. Broader close-button behavior beyond the confirmed Chrome blank-window scenario, broader activation cases, Cmd-Tab, Mission Control, fullscreen/minimized cases beyond the one confirmed Chrome window in each state, other multi-Space/display behavior, and active/long-run resource acceptance remain open. The observed WeChat single-click activation case passed separately. The four MC call-site fixes address the same API encoding defect; they do not establish MC behavior is accepted.

## Evidence and rollback

- Accepted local snapshot: `/Users/muyz/Projects/new super island/.codex-audit/checkpoints/we1-20260909175743-chrome-accepted/`. Actual installed-app ZIP was extracted, file/symlink compared and signature verified. It also contains a complete 217-file tracked source baseline verified against Git blob IDs, the 2 reviewed file overlays, all 34 required untracked build resources, diff, manifests, acceptance records and restoration README. This is a local snapshot, not a new Git commit or push; it excludes user data, permissions and signing credentials.

- Actual old accepted installed app (20260909151823): `/Users/muyz/.Trash/SuperIsland-WE1-Debug-pre-20260909175743.app`, preserved with a verified file manifest. Quit the current WE1 before any restoration; keep source/resource checkpoint instructions below.
- Current installation record: `/Users/muyz/Projects/new super island/.codex-audit/wins/2026-09-09/chrome-shared-preview/installation-state-20260909175743.json`.

- Accepted checkpoint: `/Users/muyz/Projects/new super island/.codex-audit/checkpoints/we1-20260909151823-ego-accepted/`. The actual installed app ZIP has been extracted, hash-compared and signature verified. The six source/test files are committed; 34 required untracked resources are saved separately. See checkpoint README before rebuilding from a clean checkout.
- Checkpoint review: `/Users/muyz/.codex/reviews/20260909-160226-199-WE1-accepted-Ego-Lite-version-checkpoint-and-next-acceptance.md`.

- Latest progress: PROGRESS.md, Chrome shared-preview installation. The accepted installed Ego/WeChat checkpoint remains the rollback baseline. The new two-file source patch is not committed or pushed.
- Read-only WINS research: `/Users/muyz/Projects/new super island/.codex-audit/wins/2026-09-09/research.md`.
- Persistent pre-edit snapshot and this repair's isolated diff/logs: `/Users/muyz/Projects/new super island/.codex-audit/wins/2026-09-09/cfarray-repair/`.
- Previous project package: `build/WE1-Debug/backups/SuperIsland-WE1-Debug-20260909-151823.app` (20260908163754).
- Actual previous installation: `/Users/muyz/.Trash/SuperIsland-WE1-Debug-pre-20260909151823.app` (20260908163754).
- Installation evidence: `/Users/muyz/Projects/new super island/.codex-audit/wins/2026-09-09/cfarray-repair/installation-20260909151823.json`.
- Implementation review: `/Users/muyz/.codex/reviews/20260909-150955-791-WE1-CGWindowID-CFArray-representation-repair-and-candidate-b.md`.
- Installation review: `/Users/muyz/.codex/reviews/20260909-153207-456-WE1-candidate-20260909151823-installation-and-startup-verifi.md`.

Current private API results show the exact-description API works with correct raw CGWindowID array values. The earlier claim that the API fails universally is withdrawn. Empty/partial successful responses remain legal for expired IDs, and must remain distinct from nil query failures.
