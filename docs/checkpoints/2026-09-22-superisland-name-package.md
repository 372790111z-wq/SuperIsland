# SuperIsland 对外名称统一

状态：名称修改、Release 编译、本机签名与 ZIP/DMG 校验完成；未安装，仍运行旧 160622。

## 范围

用户确认将日常使用版对外名称改为 SuperIsland。源码提交 `c0ad576c0b61689a7bf6a8f04aaf8b6ed9225583`，保留已完成的 Codex 用量刷新修复；Claude 逻辑及展示不变。

- 应用文件名、CFBundleName、CFBundleDisplayName：`SuperIsland.app` / `SuperIsland`。
- 菜单栏提示与无障碍名称：`SuperIsland`；设置窗口：`SuperIsland 设置`。
- 更新提示使用 `SuperIsland 构建号`；原更新地址、tag、资产匹配规则没有改变。
- 新增受 Git 追踪的 `scripts/package-local-release.py` 与使用说明，防止后续 Release 包又使用测试名称。Debug 专用脚本保留。
- 内部 Bundle ID、签名要求、偏好、扩展/日志目录、WE1 证据键及安全分支全部保留。没有全局替换、改账号或迁移数据。

## 构建与证据

- Release arm64 成功，构建前后 Git HEAD/tree/干净状态一致；回执为 `build/SuperIslandName.noindex/build-receipt.json`。
- 8 项现有 UpdateReleasePolicyTests 通过；没有为名称调整新写镜像测试。
- 打包器验证完整 app 文件、权限模式与符号链接清单哈希；复制前后核对，排除测试运行时、覆盖率和 debug dylib。
- ZIP 解包后、DMG 只读挂载后均严格签名通过，元数据和二进制哈希一致；DMG 校验通过并已卸载，未启动新包。
- 上一轮 Codex 修复的 24 项原生/8 项 JS 通过记录见 `2026-09-21-codex-usage-refresh.md`；本轮仅修改名称和打包，未重复运行该组测试。

## 新包

- 构建号 `20260922004644`，目录 `/Users/muyz/Projects/new super island/releases/SuperIsland-20260922-local-arm64`。
- ZIP：`SuperIsland-20260922004644-arm64.zip`，SHA-256 `02be09fae2e5444b4a3b904f9fddd32820bbe16a75acbc0120062d08665ea22f`。
- DMG：`SuperIsland-20260922004644-arm64.dmg`，SHA-256 `d8e8b3025ab1900eab2f3769bb29702bb3627affbe854b7ee3ab5c25c137f9d5`。
- 签名后二进制 SHA-256：`785693a86e575d37e0c692de27fc695fcc2db1a7093d354cc0585a2e60b0b926`。
- Bundle ID：`com.workview.SuperIsland.WE1Debug`；指定签名要求与现有安装一致。本机签名，未公证、未推送或发布远端。

## 当前安装及回退

本轮没有强退、替换或重命名正在运行的旧应用。实际仍为 `/Applications/SuperIsland-WE1-Debug.app`，构建 160622，PID 65539，二进制 SHA-256 与原验收版一致；`/Applications/SuperIsland.app` 尚不存在。

上一轮正常退出未完成，是否允许仅强制结束旧 WE1 的问题仍未收到明确答复。本次“修改吧”对应名称调整，不扩大为强退授权。后续安装应在新包与旧包检查完成后处理精确进程，保留回滚副本，改到 `/Applications/SuperIsland.app`，再回读实际进程、权限及开机启动状态；不得把包校验当作安装验收。

历史 160622 稳定 tag/包及 181025 用量修复候选包都保留。当前源码起点为 `78c67fa`，安装没有变化，无需设备回滚。新包以该检查点为准，不覆盖前一候选档案。
