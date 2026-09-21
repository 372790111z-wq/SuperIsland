# 音乐封面入口与切页诊断

当前状态：用户已确认 160622 没问题，并要求正式打包、本轮收尾。已制作本地稳定 DMG/ZIP；程序保持验收时的源码、构建号和签名；安装包普通启动默认关闭临时诊断，当前进程保留（见收尾观察）。

## 范围与回退

- 用户确认整张封面（包含右下角来源小图标）可点击，打开对应播放 App 或已有网页。开始代码、测试和安装验证；不写新 PRD。
- 分支：`feat/we1-media-source-swipe-diagnostics-20260921`。起点 `122ed6c`，原安装源码 `8754b70`。
- 144151 回退 tag：`we1-144151-shelf-zip-installed-20260921`；完整安装包已保留于 `build/WE1MediaSource.noindex/Rollback/SuperIsland-WE1-Debug-20260921144151.app`。
- 不修改播放、音量、Dock/Cmd-Tab、ZIP、暂存架滚动归属；不推送远端，不自动接管鼠标。

## 154800 实施和反馈

- 源码提交 `c5af84661b00646fbe40d9a4043f3891e9529c91`，整张封面入口覆盖首页和音乐展开页，保留独立播放/上一首/下一首/进度控件。
- Chrome/Canary 仅在浏览器检测开启、来源允许及现有自动化授权齐备时，尝试定位现有标签。按实时标题、作者、媒体状态匹配，稳定窗口/标签 ID 与 URL/媒体信息再次复核后切换；不新建、导航或控制播放。无法可靠定位时仅尝试激活浏览器。
- 脚本在后台队列，单事件超时 1 秒，遍历限 8 窗口/32 标签并检查 2 秒预算；读取媒体元数据而非正文。
- 首轮 129 项相关测试通过，Release arm64 构建及严格签名通过；安装包保留既有签名身份，已核对源码、二进制哈希及单一运行进程。
- 用户实测：QQ 音乐切到后台后点击封面可以打开；关闭主窗口后点击会收起岛，但音乐窗口不出现。运行态核对 QQ 音乐进程仍在。154800 不能计为关闭窗口场景验收通过。
- 原生缺口：`activate` 的返回值只表示请求发出；缺少恢复已关闭主窗口的 reopen，以及实际前台/窗口出现的验证。后续修复限定原生来源，浏览器不执行 reopen。

## 切页诊断与实际观察

- 独立开关 `WE1_SWIPE_DIAGNOSTICS=1`，仅 WE1 生效。正常未启用时不写日志。
- `~/Library/Logs/SuperIsland-WE1-Debug/island-swipe.jsonl` 仅含封闭模块枚举、事件/原因、数值与耗时；不含歌曲、URL、稿件、扩展 ID 或按键正文。扩展统一记为 `extensionModule`。
- 复用安全异步 writer，最多 2048 条/512 KiB，64 条待写上限，0600，拒绝符号链接；保持既有手势阈值和归属规则。
- 154800 实际运行已产生日志：一次 weather → teleprompter 状态切换用时约 32.7 ms，下一主队列回调用时约 26.5 ms。该数据仅代表状态提交与队列响应，不是完整绘制时延，也不能证明此前卡顿已修复。
- `page.appeared` 只表示透明观察节点出现；不会强制重建真实页面或改变提词器初始化。
- 154800 的候选、安装、运行清单分别归档于 `build/WE1MediaSource.noindex/*-154800.json`，切页摘要为 `weather-observation-154800.json`。

## 验证边界

- 单元测试使用注入端口，未操作真实 Chrome 标签；AppleScript 仅做语法编译。因此真实浏览器选页仍待实机验证。
- 若播放来源恰在 focus 脚本已派发后发生变化，后续检查可阻止激活旧应用，但不能撤销已完成的标签选择；不宣称任何时间点都原子取消。
- 天气到提词器的历史卡顿根因未知，诊断已接入，不把诊断实现称为卡顿修复。

## 关闭主窗口场景补充修复

- 原生来源每次明确点击只向仍运行的目标 PID 发送一次 `kAEReopenApplication`；使用不等待回复、不交互、不弹授权的发送标志。已经退出的来源不会重新启动。
- 恢复窗口时补充与既有 Dock 路径一致的 AX 前台、聚焦与 raise；随后异步等待最多约 1 秒。仅当原进程仍运行、已成为前台且有实际可见普通窗口时，才向 Manager 报告成功。
- 网页来源不发送 reopen。除已知浏览器名单和缓存网页来源之外，再检查 LaunchServices 的 HTTP/HTTPS handler 与来源 Bundle 声明的 URL schemes；无法确认按未知处理，不允许 reopen。
- 本机只读验证：HTTP/HTTPS 各 7 个 handler 均可读，QQ 音乐不在列表，且声明的 scheme 不含 HTTP/HTTPS，因此允许原生 reopen。
- 139 项相关回归通过，其中来源打开 24 项、切页诊断 9 项，其余 106 项覆盖此前暂存/ZIP/滚动/拖放边界。随后用户确认包含 QQ 主窗口重开修复的 160622 版本没有问题。

## 160622 安装记录

- 已安装 `/Applications/SuperIsland-WE1-Debug.app`，版本 `20260921160622`，源码 `fd8ea9873bd6f30577dcc06daa04cab2ba086273`，新进程 PID `65539`。
- 可执行文件 SHA-256：`e2087944c38eedb767288ba0a54bb9cebaffb1b2aa99f2e91e58fb8a87b522aa`。Release arm64、严格签名、稳定 designated requirement、安装后哈希及运行态回读均通过。
- 仅替换并重启 WE1。154800 另存于 `build/WE1MediaSource.noindex/Rollback/SuperIsland-WE1-Debug-20260921154800.app`，144151 完整回退包保持不变。
- 安装验证期间启用切页诊断，暂存诊断未开启；打包默认普通启动不启用临时诊断；本次退出请求未完成，当前进程尚保留临时诊断。源码与检查点仅本地 Git 保存，未推送远端。
- 最终自动验证：`build/WE1MediaSource.noindex/Tests-final.xcresult`（139/139）、`release-final.log`、`candidate.json`、`installation.json`、`runtime-verification.json`。
- 2026-09-21 用户在该验证请求后明确回复：“这版没问题了，先正式打包吧。等有问题了我再找你。”据此记录本版用户验收，不扩大为未单独测试场景的逐项验证。

## 已验收稳定安装包

- 交付目录：`/Users/muyz/Projects/new super island/releases/WE1-20260921160622-arm64/`。
- DMG：`SuperIsland-WE1-20260921160622-arm64.dmg`，11,120,773 字节。SHA-256：`ed0aac99d20b728612f8e368dac6c6bdeb8a36bcee19e53172ee7c6263e7d661`。
- ZIP：`SuperIsland-WE1-20260921160622-arm64.zip`，11,317,207 字节。SHA-256：`f4efc62d4899fe451876e9db38e4a680a5fbea4befab4a017374726d0276a8a9`。
- 同目录保留 `使用说明.txt`、`manifest.json`、`SHA256SUMS.txt`。适用 Apple 芯片 Mac / macOS 14+；应用版本仍为 1.0.9 / 20260921160622。
- 直接封装已验收签名包，未重新编译、修改 App 或重新签名。候选、已安装包、暂存副本、只读挂载 DMG 内 App、ZIP 解压 App 的完整文件内容、权限与软链接逐项一致，严格签名全部通过；DMG 镜像和 ZIP 完整性检查通过。
- 包内继续保留当前 `SuperIsland-WE1-Debug.app` 名称及 bundle identity，以沿用已有授权和配置。构建本身为 Release 优化；签名为本机稳定签名，未 Apple Developer ID 公证，未上传或公开发行。
- 收尾尝试通过普通退出、再通过 WE1 自带 SIGTERM 正常退出处理器退出诊断模式，均未观察到进程退出；没有强制终止或重新安装。当前 160622 进程保留，应用文件和回退包未变。实际状态回读见 `build/WE1Accepted160622.noindex/normal-launch.json`，完整比对清单为 `bundle-files.json`。
- 验收检查点：`we1-160622-accepted-20260921`。本轮到此收尾，后续发现问题再继续。

### 收尾观察

普通退出请求返回已发送，但进程 PID 65539 保留。三秒采样主线程主要停在正常 AppKit 事件等待，未观察到持续主线程卡死；退出未完成的原因尚未确定，不继续扩展开发。当前进程的切页诊断仍启用且有界，安装包下一次普通启动默认关闭。记录为未解决的运行态观察，不将其写成诊断已关闭或正常重启成功。
