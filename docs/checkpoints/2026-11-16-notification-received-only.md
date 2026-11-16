# 通知仅承接实际消息：通用修正

用户明确确认：停止由任务完成状态主动生成通知，所有应用共用该规则；不是按 Codex 特判。

## 范围与结果

- 基线 0eba7ad，worktree battery-simple-20261116，分支 feat/battery-simple-20261116。原主仓现场未改。
- 断开 KeepAwakeService.shared 到 NotificationManager 的统一连接；内部任务完成观测保留，任务状态、保持释放、接入许可和回顾不变。
- 移除 TaskCompletionNotifications 主动生成岛内消息、提交 UNNotificationRequest 及自身回声过滤的实现。保留同文件的内部 TaskCompletionEvent 类型供任务观测使用，不再是通知源。
- NotificationManager 拒绝所有 task-completion 合成事件，移除对应的来源绕过和去重例外。真实 macOS、兼容应用和扩展消息按原来源与总开关展示，不按应用名或文案屏蔽。
- 保持唤醒设置说明同步新行为；KA1 v0.8 与归档 20261116-4 的全文、F10映射及current/index一致。历史v0.7、既有HTML快照保留，本轮没有新页面或交互入口。

## 实际验证

- Debug 构建和 XCTest：build/ReceivedOnlyRegression.xcresult，80项通过，0失败。
- NotificationRoutingTests 4项（其中跨所有当前来源加未知未来来源）；KeepAwakeCompletionCompatibilityTests 3项（含原生设置页）；KeepAwakeCodexServiceTests 20项；KeepAwakeRecapTests 53项。
- 同文案的真实Mac/扩展通知仍可入列；关闭总开关清理、关闭来源拒绝、关闭后重新开启不恢复排队历史。旧完成偏好、三种设备类型、所有来源不影响状态与释放规则。
- 首次测试使用目录名SuperIslandTests作target被scheme拒绝，未运行用例；改用项目真实target SuperIslandWindowEnhancementTests 后运行通过，不把配置失败当成代码失败。
- 全源码搜索确认不再存在 UNNotificationRequest 发送器或 receiveTaskCompletion/TaskCompletionNotifications 连接；git diff --check通过。

## 对抗性复核与边界

- 不用应用名单：未知来源也不能通过旧合成入口。
- 不用正文黑名单：真实收到的“任务完成”消息仍可展示。
- 不只关闭系统横幅：岛内合成入口也一并移除。
- 不将事件监测等同通知：内部完成观测保留，生产单例不连接通知模块。
- 不清理系统历史、不改系统权限或来源接入，不改电池代码。
- 未替换本机安装版、未推送GitHub、未发布。当前用户仍在运行上次安装版，安装后真实消息仍须独立验证，测试注入消息不能代替实机验收。
- 本次变更未提交，回退仅需按此差异恢复指定源码与当前归档指针；不要回滚或覆盖已完成的电池实现。
