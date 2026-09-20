# WE1 原有设置恢复版 165341 安装记录

## 安装身份

- 源码：`c7036c9fbeb52640b8417cd113fb40b827585040`。
- 分支：`fix/we1-restore-original-settings-20260920`。
- 安装：`/Applications/SuperIsland-WE1-Debug.app`，显示名称 SuperIsland WE1。
- 版本／构建：1.0.9 / `20260920165341`。
- Bundle ID：`com.workview.SuperIsland.WE1Debug`，保持原 ID 和签名身份。
- 主程序 SHA256：`527df97ad2cd0a02c8b2b1ca6d58043111cccd45e4cea35f9c6d0b8333e28671`。
- 文件逻辑体积：20,138,998 字节，约 20.14 MB。Release 优化、无 coverage、无 Debug dylib；新增体积主要为补齐的 WhatsApp provider。
- `codesign --verify --deep --strict` 通过；与旧版 designated requirement 相同。

## 验证与观察

- 最终 502 项 XCTest 全通过；4 项 JS、5 项 Python 测试通过。
- WhatsApp 包内产物哈希与准备记录一致，六份扩展 manifest 均在包内。Provider 在无 node_modules 的隔离目录 ready / EOF 退出测试通过，无账号连接。
- 安装前旧进程 10794 正常退出；新安装路径运行进程 39204。只替换 WE1，未启动 WINS 或重启其他应用。
- 原生设置显示构建 20260920165341；高级页显示器菜单可打开，重置和检查更新按钮可用，检查结果为“暂无适用更新”。未执行真实设置重置。
- 窗口增强页辅助功能、屏幕录制仍显示“已生效”；快捷删除 Cmd-S、隐藏/显示 Cmd-D 等既有设置保留。
- 只读当前应用域确认六项扩展已被发现。用户开始操作后启用状态发生变化；没有把这些变化当作代理实测。
- 界面工具连续两次报告用户更改设置页，停止了自动点击并询问控制安排。未完成的原生逐项验证：显示器切换回读、重置弹窗取消、番茄钟启停和重启保存。已完成的源码／隔离测试不等于这些交互全部验收。
- Linear/Last.fm 授权、WhatsApp 扫码和消息、AI 用量真实账号、Agents CLI hooks 未由代理执行；需用户主动启用并验证。

## 旧版与回滚

`/Applications` 只保留这一份 SuperIsland WE1。旧 160408 已可恢复移入：

`/Users/muyz/.Trash/SuperIsland-WE1-Debug-20260920160408.app`

更早原版和 102559 回收站副本仍保留，未清空废纸篓。回滚时正常退出新版，将所选旧 WE1 恢复到相同安装路径；源码基线标签 `we1-160408-optimized-installed-20260920` 保留。

本机证据在 `build/WE1RestoredSettings.noindex/`：`candidate.json`、`installation.json`、`final-file-verification.json`、`release.log`、`tests-final.log`。原始构建副本已注销 Launch Services 注册；不会把它们作为安装入口。代码与记录保存在本地 Git，本轮未推送或创建远端 Release。
