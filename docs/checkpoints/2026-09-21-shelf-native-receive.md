# Finder 文件拖放修复（2026-09-21）

## 来源与边界

- 分支：`fix/we1-shelf-native-receive-20260920`。
- 修复源码：`41f3fadbd50a38bd89dd18f396d25f1572976e69`。
- 原安装版本：`20260920181501`，检查点 `we1-181501-shelf-drop-installed-20260920` / `fd4ae1e`；该版本文件拖放未通过用户验收。
- 用户确认修复并授权使用专用文件做原生拖放测试；共享仅打开 AirDrop 后取消，没有选择收件人或发送文件。

## 原因与修改

Finder 的 TXT 拖放在 SwiftUI provider 中声明为文本，但实际 `loadItem` 返回 NSURL。旧文本提取只接受字符串或 Data，丢失了这个有效文件对象。现在先保留 file URL，再处理原有文本路径。真实 PDF / ZIP 走原有 fileURL Data 路径，无需扩展任意二进制接收范围。

文件进入紧凑岛前，用只读全局事件观察器识别本次按下之后新发布的 drag pasteboard 类型和代次；在岛下方 96pt 范围提前展开现有共享／暂存区。拖放展开不等待动画，真正接收仍由原 DropDelegate 完成。观察器不读文件内容、不吞掉或重放事件；只移除自己的目标 ID，按键结束、睡眠、会话和面板失效均清理。每次按住手势最多提前展开一次，离开后原有实际 drop target 仍照常工作。

没有保留诊断用的 48pt 窗口偏移、held-hover 绕过或临时功能关闭。Dock、Cmd-Tab、调度中心、窗口分屏源码未修改；未修改用户的持久快捷键与窗口增强配置。有限元数据日志仅在 WE1 且显式 `WE1_SHELF_DIAGNOSTICS=1` 时启用，正常启动禁用。

## 验证

- 49 项针对性测试通过：provider 10、诊断 7、文件靠近状态 8、drop target 7、窗口拖动 hover gate 10、Zilan 输入隔离 7。
- Release arm64 构建、稳定签名及严格验证通过。没有测试包、debug dylib 或覆盖率代码混入安装候选。
- 正常窗口增强设置下，从紧凑岛拖入 TXT / PDF / ZIP 均出现真实 `perform → extract=1 → receive=1` 记录；重复文件 `added=0` 为去重，不能等同新增。
- 正常设置下，TXT 拖入 AirDrop 出现真实系统 AirDrop 窗口；以明确“取消”按钮关闭，未发送。
- 原生拖动测试 Finder 窗口：位置从 `(30,270)` 到 `(30,318)`，拖板代次 41 保持不变，没有 `approach.file/enter`；随后恢复位置。
- 最近一次 PDF 标题区拖放在释放后 0/150/400/800ms，Dock mc 标记缺席、AX 查询无错误、同一 Finder 窗口无几何变换。

调度中心结论保留边界：早期 helper 仅凭 Dock `mc` 标记判定，可能把残留节点计作展开，也把读取失败计作 false。后续补充同一窗口 ID 的 AX/WindowServer 几何证据与截图后，确实重现了直接拖至顶部中央 `(756,29)` 的 MC。**WE1 完全退出后，同一路径仍重现**，见 `we1-off-top-control-2.json` 和 `we1-off-top-screen.png`：新拖板代次43→44、Finder窗口尺寸差437pt、mc根存在、截图显示总览；随后取消拖动、退出MC，恢复WE1。此对照证明触发不要求WE1运行，尚未进一步区分系统与其他驻留程序，不把原因直接归给小米服务。

这版通过提前展开接收区，让文件在岛下方即能进入实际目标；不是关闭或拦截系统MC功能。直接继续推至屏幕最上沿仍可能触发，不宣称已消除所有顶部路径。截图排除岛是 `sharingType=.none` 设置，不能据截图缺岛判定消失。

候选路径测试产生了 macOS 屏幕／音频访问提示；未代替用户授予新权限。存在其他软件的文件传输提示，未关闭这些软件。

## 构建与恢复

- 构建：`20260921001213`。
- 可执行文件 SHA-256：`0c051a95983b8a000cbbe0db050a782666d5ab269899c35f678b425863579adb`。
- 原 181501 SHA-256：`a20ab536badac537708a209e0a5def2072e0d09c149bdef9981ada59010df7fe`。
- 安装目标：`/Applications/SuperIsland-WE1-Debug.app`。
- 安装前保留完整 181501 包至 `build/WE1ShelfNativeReceive.noindex/Rollback/SuperIsland-WE1-Debug-20260920181501.app`。
- 恢复时只正常退出 WE1，保留新包，再还原备份到同一 Applications 路径、验证签名并启动；不清理偏好、钥匙串或用户资料。
- 本轮仅本地提交，未推送 GitHub。

原生记录、签名清单和 xcresult 位于忽略目录 `build/WE1ShelfNativeReceive.noindex/`。代码与自动原生复测不等于用户验收。

## 已安装与安装后复测

- 已替换到上述 Applications 路径，完整181501包已保留于上述Rollback路径；安装与备份的SHA-256、严格签名验证均匹配。
- 最后恢复运行PID85179，实际执行路径为安装目录；正常启动不带诊断环境变量，无临时功能关闭参数。
- `installed-native-exact-new-tray-3.json`：从Finder列表真实拖动唯一新文件 `WE1-drag-test-installed.txt`，新拖板44→45，移至 `(756,72)` 即展开，释放至实际暂存目标。持久化项目由3变4，精确新文件路径出现一次；释放后4轮MC根缺席，Finder窗口无变换。
- `installed-native-exact-share.json`：同一精确文件新拖板45→46，移至共享目标，系统AirDrop窗口实际出现，明确“取消”按钮执行成功；没有选择收件人或发送。4轮场景检查均无MC根及窗口变换。
- 早期名为 `installed-native-tray.json` 的测试参数未被helper识别，实际回退到旧TXT；它不能证明新文件失败。已将helper改为四个精确fixture白名单并输出文件名。列表模式不预先二次点击文件名，避免进入Finder重命名状态；必须看到新拖板才算真实拖动。
- 已通过各项目的“移除”菜单清掉四个专用Shelf测试项目，读回总数0；源测试文件保留于忽略构建目录。测试Finder窗口恢复原图标视图、`(298,270,920,436)`；左右鼠标均已释放。
- 测试中出现的macOS屏幕／音频授权提示仍需用户决定。尝试“打开系统设置”只导航，没有授予权限；已异步询问授权，未收到回答前不点击“允许”。
- 用户手动验收、顶部系统/驻留程序行为的进一步处理及权限确认仍开放。本轮没有修改系统热角、系统MC设置或其他驻留软件。
