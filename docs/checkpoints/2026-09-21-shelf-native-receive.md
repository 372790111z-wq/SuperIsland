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

调度中心结论保留边界：早期 helper 仅凭 Dock `mc` 标记判定，可能把残留节点计作展开，也把读取失败计作 false。曾有单轮标记出现但文件已正确收到，未保存当时完整画面；不能据此断言该轮是真实 MC，也不能声称所有路径的误触发已彻底消除。最后补充同一窗口 ID 的 AX/WindowServer 几何证据，以上述具体复测结果为准。截图排除岛是 `sharingType=.none` 设置，不能据截图缺岛判定消失。

候选路径测试产生了 macOS 屏幕／音频访问提示；未代替用户授予新权限。存在其他软件的文件传输提示，未关闭这些软件。

## 构建与恢复

- 构建：`20260921001213`。
- 可执行文件 SHA-256：`0c051a95983b8a000cbbe0db050a782666d5ab269899c35f678b425863579adb`。
- 原 181501 SHA-256：`a20ab536badac537708a209e0a5def2072e0d09c149bdef9981ada59010df7fe`。
- 安装目标：`/Applications/SuperIsland-WE1-Debug.app`。
- 安装前保留完整 181501 包至 `build/WE1ShelfNativeReceive.noindex/Rollback/SuperIsland-WE1-Debug-20260920181501.app`。
- 恢复时只正常退出 WE1，保留新包，再还原备份到同一 Applications 路径、验证签名并启动；不清理偏好、钥匙串或用户资料。
- 本轮仅本地提交，未推送 GitHub。

原生记录、签名清单和 xcresult 位于忽略目录 `build/WE1ShelfNativeReceive.noindex/`。安装和安装后的验证待下方补记，代码与候选复测不等于用户验收。
