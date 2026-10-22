# 保持唤醒需求稿 0.1 · 验证记录

日期：2026-10-21（Asia/Shanghai）。状态：用户已确认 HTML；PRD v0.1 已确认并获代码实施授权，当前实现中。

## 范围与现场

- 用户已确认：现有 SuperIsland 菜单栏新增「保持唤醒」子菜单；设置侧栏新增独立管理页；首版包含单独授权的 MacBook 合盖运行；覆盖 HoldMyLid 全部任务来源。
- 基线：main / c5cccc703dff1793bc7ee4dcc65711de59e0c098。
- 独立分支：feat/keep-awake。独立 worktree：`/Users/muyz/Projects/new super island/worktrees/keep-awake`。
- Codex 托管 worktree 工具因当前会话上层目录不是 Git 仓库返回 `Not a git repository`；随后在已核实的实际子仓库中用 Git 创建 worktree。
- 原型阶段只新增本稿与 `keep-awake-v0.1.html`。没有修改业务代码、运行中的 App、系统电源设置或真实 agent 配置；没有推送远端。
- 视觉基线来自现有 `SettingsView.swift`、`AppDelegate.swift` 菜单结构及截图挂绳原型。本轮原生界面读取两次超时，未将源代码检查表述为新的原生 UI 验收。

## 来源清单与证据边界

共 17 个产品来源或独立接入形式：Claude Code、Claude Cowork、Codex CLI、Codex 桌面端、OpenCode、Gemini CLI、Pi、Copilot CLI、Hermes CLI、Hermes Gateway、Cursor、Cursor Agent、Cline、Aider、Conductor、Goose、Windsurf。

这是安装包与官网清单的并集，拆分了 Codex 桌面端/CLI 和 Hermes CLI/Gateway，并不代表 17 个已验证适配器。Windsurf 来自官网 FAQ，本机安装版枚举中尚未确认。Cowork、Conductor、Goose、Cursor Agent 的当前检测方式仍待核验。

当前安装版 HoldMyLid：1.0.6 (7)，原主程序 SHA-256：`32498369d74f60a5d637294308cbe4a0e065d6dffe593eb678cfa9816086fea1`。REA 分析的是临时目录中的 arm64 切片，安装包没有修改。

- 任务事件脚本/插件：安装包有 Claude、Codex、OpenCode、Gemini、Copilot、Hermes、Pi 等资源；存在脚本不证明已在本机接通，也不证明当前版本的完整事件覆盖。
- 主程序创建唤醒断言：REA `ev_fe6d26b332e1ac0d37d9e4aa8e31118141f38139237f05de2d2b275d4dbbe99d`。
- 主程序 helper 调用及 30 秒续期检查：`ev_f99abbe78a9d330f8fb7a17ac6a55cc97db9e955732e96c94311a35335b75aa8`、`ev_5b8efcbb5254ad849333e84773c003354a1cc2fd6c509c0380945e45d2305c6f`。
- helper 存在代码签名要求、sleep-disable 参数及 180 秒租约计时：`ev_eba66bc73cf3a5e284ac8ef0871b947cac0747f2e66ec5448dbfe78d51bd0963`、`ev_444932365922035a665b3e977ee1330c969df1d29099a6960e59381a39eacf22`、`ev_49902951c1743146d925f61c75a2f6bb46845f5e1669d75bc15a9f810ce9afe6`。
- 租约事件回调调用关闭路径：`ev_f1b4bc10ed6a078d41d132ae06118bbb4eb6b4a831b4ad4654afbb29cddba21b`。
- 以上均为静态反编译证据，Swift 类型恢复存在局限，不是原始源码，也不证明运行时恢复成功。新功能应独立实现，不能直接复用对方签名绑定的 helper。
- 参考：[产品官网](https://holdmylid.app/)、[Apple 防止空闲休眠接口](https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridlesystemsleep)。Apple 明确说明该接口不保证阻止合盖等其他原因导致的睡眠。

## 浏览器实测

后端：ego-browser；Task Space 2，`SuperIsland 保持唤醒需求预览 20261021`；页面 p1。预览 URL：`http://127.0.0.1:8768/keep-awake-v0.1.html`。HTTP 服务仅绑定 127.0.0.1。

通过实际点击、选择和页面回读验证：

- 默认关闭；开启但无来源时显示等待接入。
- 手动保持开始、暂停/结束暂停、计时到期关闭。
- 菜单与设置状态同步；菜单停止同步关闭设置开关。
- 有效事件触发自动保持；全部空闲进入延迟释放；快进后释放。
- 失联显示未知，宽限到期释放，不显示任务已完成。
- 低电量优先保护；条件仍不满足时拒绝恢复；过热优先保护。
- 合盖授权失败时区分普通唤醒与合盖未就绪；模拟授权成功后显示独立就绪状态。
- 异常退出显示等待租约；快进后展示演示释放结果。
- 恢复冲突保持待处理；人工核对后关闭功能。发现并修正了此前异常退出状态在冲突核对后残留的问题，复测通过。
- 来源搜索、接入失败、模拟接入成功后保持空闲、设置运行事件、断开后不再采用旧状态。
- Mac mini 隐藏物理刘海、合盖、辅助程序、电池阈值与电池模式选项；普通保持仍可使用。切回 MacBook 显示对应设置。
- 1440px 概览、来源页与菜单截图已查看；1280px 页面宽度无水平溢出；390px 手动策略页、保护页与子菜单无水平溢出，子菜单边界为 x=81..371。

注意：Ego 的设备尺寸模拟不会跨 CLI 调用持续生效。一次菜单测量实际回到 1920px，未作为移动端通过证据；随后在同一调用中重新设置 390px 并测量通过。

完成时清除设备尺寸模拟、重置演示，保留关闭状态及已展开菜单，`finish({keep:['p1']})` 后将结果页交给用户查看。没有把原型回读当作原生 App 验收。

## 确认记录

2026-10-21，用户明确回复「可以，HTML 没问题」。HTML 保持原样，SHA-256：`595dfc972b169f389c3712d9efdf402a20896110d855c843b81642013acf7274`。正式需求候选为 [KA1 PRD v0.1](../docs/product-package/06-SuperIsland保持唤醒PRD-KA1.md)，随后用户明确「PRD 确认，开始实现」。实现和设备验收结果另记，不能由 HTML 确认推导。

- 已确认 HTML 中的交互与默认值：默认关闭、仅接电、20% 阈值、遵循低电量模式、空闲/等待确认后 30 秒释放、失联最多宽限 3 分钟。

## 仍待确认与验证

- PRD 中的细化规则与验收条款已获确认；实现验证仍按分层证据记录。
- 各来源当前接口、事件序列、等待状态、多个并发会话聚合和陈旧事件处理。
- 真实辅助程序授权、有限租约、退出/崩溃/重启及与其他电源工具冲突时的恢复。
- MacBook 合盖无外屏/有外屏、电池与接电场景；Mac mini 实机行为。
- 业务实现已开始；详见 [KA1 实施记录](../docs/KA1-implementation.md)。正式安装与完整设备验收尚未完成。
