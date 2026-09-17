# WE1 文件快捷删除与窗口收起/恢复：源码检查点

## 范围与基线

- 分支：`feature/we1-file-shortcuts-20260917`。
- 基线：`55d6ad6` / `we1-171017-accepted-20260916`；交互草稿提交 `55df4c1`。
- 用户确认交互并明确要求“可以，实现吧”；采用仅恢复本批收起窗口的范围。
- PRD：`docs/product-package/03-SuperIsland窗口增强集成PRD-WE1.md` 功能点 5、6。
- 交互参考：`prototype/we1-file-shortcuts-v0.1.html`；标注版本 `20260917`，保留旧版与 TR1/TR2 原内容。

## 已实现

- 新增“快捷删除文件”设置、独立开关和 `file.moveToTrash` 绑定，默认关闭且未绑定；沿用录入、清除、冲突预检与失败回退。
- 独立 Carbon 注册器仅在 Finder 前台且功能可用时注册，不加入窗口动作或 Cmd-Tab 事件 tap。切走、停用、配置改变、退出准备时注销并丢弃旧回调。
- 在接收事件和执行前分别校验按键周期；物理释放后才接受下一次文件操作。探测期间释放按键或改变上下文时保守取消，不补做旧删除。
- 通过辅助功能调用 Finder 自身明确的“移到废纸篓”菜单命令，校验名称、Command-Delete 菜单属性、启用状态、AXPress 能力和安全焦点。排除文本编辑、对话框、同快捷键的“放回”、永久删除与清空废纸篓。
- 对 Finder 可提供的 AX 选区元素身份做前后对比；不读取文件内容或记录文件路径。选区属性不支持时使用严格内容焦点及原生命令准入。AX 探测总预算 250ms，单请求上限 20ms。
- “隐藏所有窗口”改名“隐藏/显示所有窗口”，保留 `action.hideAll` 与既有恢复会话。仅该窗口切换键增加按下/释放去重，其他布局键保留原有重复行为。
- Cmd-Tab、Dock、调度中心监视器和最小化会话源文件与稳定基线字节一致；Chrome 全屏移屏实现未改。

## 本轮验证

- `xcodebuild build-for-testing`：通过，编译完整应用及含新增测试的 XCTest bundle，没有运行 App 宿主。
- 独立 Swift package：31 项逻辑测试通过，0 失败（偏好 5、按键周期 10、Finder 命令/焦点/选区策略 16）。编译的源文件与工作树文件逐一校验 SHA-256 相同。
- `xcodebuild analyze`：通过。
- `git diff --check`、PRD/归档全文同步、版本指针对齐、20 个标注 ID 唯一及来源检查：通过。
- 首次编译的 Carbon 参数 `UInt32`/`Int` 错误已修复后重新编译通过。Xcode 报告现有 CoreDevice/iOS Simulator 组件版本告警，不阻断本次 macOS 编译；没有修改 Xcode 或安装依赖。
- Xcode 初次编译自动登记了构建目录 App 的 Launch Services 记录；已仅注销该生成物，后续分析关闭自动登记。没有安装或启动该 App。

本机日志位于 `build/FileShortcutsValidation/`：`build-command.json`、`build-incremental.log`、`analyze-command.json`、`analyze.log`、`logic-tests.log`；无宿主测试包及源文件哈希在 `LogicTests/`。这些是本地构建证据，不是安装/实机验收记录。

## 实现阶段结束时的状态与待验收

当前仍运行 `/Applications/SuperIsland-WE1-Debug.app`，版本 `20260916171017`；本次没有替换、重启或修改其权限。没有操作真实文件、窗口、鼠标或前台应用。旧 371 项 hosted XCTest 本轮未运行，不能借用旧结果作为新版本验收。

用户空闲并允许实机操作后，再打包安装候选、验证：

1. Finder 与桌面的可丢弃文件能移到废纸篓并恢复；未选择文件保留；文件夹、图标/列表等视图兼容性。
2. 录入/清除/重启持久化、冲突、空选择、重命名、搜索、对话框、排除 Finder、禁用功能及权限不足。
3. 长按、快速释放、切走再切回、锁屏/解锁后无重复或迟到删除。真实 Carbon 和 Finder AX 行为尚未验收，未知菜单语言或不支持的 AX 结构会拒绝执行。
4. A/B 打开、C 预先最小化：连续两次只收起/恢复 A/B；已关闭窗口不重开；部分失败保留下一次恢复机会。
5. 回归稳定版本已确认的 Cmd-Tab 首次点击/退出、Dock 预览、调度中心关闭与 Chrome 全屏移屏。

代码、构建和逻辑测试完成不等于新功能已经在当前运行 App 生效。

## 2026-09-17 安装记录

用户随后明确要求“安装”。已从代码提交 `73ec0ad` 的当前 DerivedData 产物打包，使用与旧版相同的 `SuperIsland WE1 Debug Local Code Signing` 证书和稳定 designated requirement。

- 已安装并启动：`/Applications/SuperIsland-WE1-Debug.app`，构建号 `20260917182138`，PID `38125`。
- 原稳定版 `20260916171017` 已备份至 `build/WE1-Debug/backups/Installed-SuperIsland-WE1-Debug-171017-before-182138.app`；101 项文件/符号链接及模式与原安装版一致。
- 旧 PID `91579` 经 WE1 正常退出处理完成，未强制结束；旧进程事件 tap 已归零。
- 候选暂存与安装目录的 101 项清单一致，签名严格验证通过；运行进程确实加载安装目录内的新 `SuperIsland.debug.dylib`。
- 原始源载荷指纹：`f0823affcd051b4e377bd7a24a0f3fee2d277592c7aae0454eca89aa864d7b75`。未更换签名身份、bundle ID、用户配置或隐私授权。
- 安装器没有开启文件功能或填写快捷键；只读回读时该功能开关已为开启状态，保持用户当前设置。
- 安装元数据、清单、运行载荷及事件 tap 证据保存在 `build/FileShortcutsValidation/installation.json` 等文件中。

本次仅完成安装和启动核验，未代替用户操作文件、鼠标或进行全局快捷键测试。上方各项实机验收仍待完成。
