# WE1：窗口分屏拖动与主岛悬停互斥修复

## 范围与来源

- 从 `5c33118` 创建 `fix/we1-snap-hover-20260918`，复用工作树 `we1-file-shortcuts`；旧功能分支仍指向原检查点。此前 185346 的原生测试证明，拖动窗口选择分屏区域时主灵动岛也会展开。
- 按已确认 WE1 PRD 的实现修正处理，沿用原需求和标注版本；没有新增布局、入口、设置或交互选择器。
- 只修主岛的悬停自动打开。保留主动打开、通知/HUD、已展开或锁定的主岛、Shelf 文件投放；Cmd-Tab、Dock、调度中心、Chrome 全屏移动和文件快捷键代码均未修改。

## 实现

1. 仅在同一 PID、同一 AX 窗口的实际位置移动至少 4pt 后开始悬停抑制。普通鼠标按下、正文选择、文件拖放不会启动；识别为窗口缩放时解除。
2. 独立 `WindowDragHoverGate` 管理拖动、指针位置和代次。主岛收到悬停、排入计时器和执行计时器时都检查；开始/结束/移出均使旧任务失效。
3. 结束时读取实际鼠标与可见 IslandPanel 范围，覆盖主岛入场回调迟到的情况。如果仍在主岛范围内，需要真正移出再进入；不重放拖动时的悬停，也不让浮层消失造成的迟到 exit 回调提前解锁。
4. stop、禁用、新序列、窗口失联、mouseUp、取消和 Aero Shake 共用幂等清理。只在实际移动期间运行 100ms 恢复检查，按钮连续抬起 300ms 后回收漏掉的 mouseUp；持续按住的长拖不超时。未增加 event tap 或消费原生事件。
5. 主岛视图即使公开 hover 为 false、状态为 compact，也校正局部 hover 标记；隐藏面板或移除显示器不会永久阻止下一次悬停。保留 Shelf 的命中、文件接收与完成回调。

## 构建验证

- 14 项纯逻辑 XCTest 实际执行通过，0 失败：8 项悬停状态/旧任务/移出再进入，6 项丢失释放恢复/长拖/短暂按钮间隙。测试直接编译复制的生产门控源文件，SHA-256 与工作树一致，不读取 UserDefaults 或操作桌面。
- 完整 `xcodebuild build-for-testing` 和 `xcodebuild analyze` 通过；未启动 XCTest App 宿主。独立审查复核清理路径、计时器代次、局部 hover 校正和 Shelf 边界。
- 候选构建 `20260918002729`，稳定签名 `SuperIsland WE1 Debug Local Code Signing`，Bundle ID `com.workview.SuperIsland.WE1Debug`；签名及 designated requirement 校验通过。
- 候选源载荷指纹：`3b6ef52b214a839359eb67b6ca0180902ebe6ade4520cd1c2cd1647899208d15`。
- 本轮构建/测试记录在 `build/SnapHoverRepair/`。候选实机结果单独记录，不能以以上检查代替安装与原生验收。
