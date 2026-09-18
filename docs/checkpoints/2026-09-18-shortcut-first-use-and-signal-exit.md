# WE1：首次文件删除诊断与退出调度修复

## 范围与保留版本

- 从用户实测记录 `3c05d07` 创建 `fix/we1-shortcut-stability-20260918`。回退标签 `we1-092348-user-verified-20260918`、092348安装及此前备份保留。
- 用户授权继续稳定性收尾，本轮只改代码、测试和打包，不发鼠标/键盘事件，不终止或重启应用。运行中的 `/Applications/SuperIsland-WE1-Debug.app` 仍为20260918092348/PID94490。
- 按 feature-lifecycle-assistant B 类实现修正；文件移废纸篓、收起/恢复需求和20260917标注不变。没有修改Cmd-Tab、Dock、调度中心、全屏移动、收起恢复策略或用户偏好。

## 已确认事实与未知

- 用户在092348反馈第一次桌面删除出现提示，随后删除和收起/展开正常。该提示的原文、具体失败阶段未知。
- 当前092348交互日志回查有1272条记录（mission_control、dock、cmdTab），没有Finder删除事件；源码只有HUD反馈，不能从已有日志还原原因。因此本轮**不宣称首次删除问题已修复**，也不增加自动重试或放宽安全检查。
- 旧003847退出采样的88/88主线程样本处于main dispatch的SIGTERM回调→NSApp.terminate→AppKit嵌套等待。恢复及reply依赖另一个MainActor Task，18秒超时在该Task开始后才建立。
- 另确认旧isHandlingTerminationSignal置true后不复位：恢复失败取消退出后，后续SIGTERM仍被忽略。

## 实现

### WE1退出入口

- 新增 `WE1TerminationSignalScheduler`，信号回调只排队，通过主run loop执行退出并显式唤醒，避免在原main-dispatch回调尚未返回时进入AppKit等待。
- 排队前与执行前检查已有deferred quit；重复信号合并，正在退出时不嵌套。正常Quit抢先开始时撤销旧排队请求，避免取消退出后旧请求再自动触发。
- terminate取消返回后解除处理状态，允许新的显式信号重试。仍先幂等清理子进程，仍走原applicationShouldTerminate与窗口恢复、18秒失败取消协议；不改变正式版信号行为。
- 生成的xcodeproj在本仓库被忽略；本地已加入源文件/测试引用并通过格式检查，project.yml原有目录扫描可再生，无需强制跟踪生成工程。

### 文件删除诊断

- 只在现有executor结束时记录阶段、结果、耗时及既有焦点结构的固定分类，复用有界异步记录器，使用独立 `~/Library/Logs/SuperIsland-WE1-Debug/finder-shortcuts.jsonl`，不受指针日志节流影响。
- 记录区分modal/editable未知、真、假，子角色固定分类和首层选区缺失/空/非空；不保存文件名、路径、URL、内容或原始AX字符串，不新增AX查询。生产版日志门禁不变。
- 仍只有一次AXPress；250ms总期限、20ms单次请求、三次焦点与两次菜单身份检查保持。未知执行结果不重试，成功只记requested，不声称文件已经删除。
- 11个元数据字段，code最长63字节；独立流使用既有128项缓冲和2MiB轮转。oversized/invalid分类通过辅助函数测试，但生产路径可能更早拒绝，不能声称所有底层AX失败已完全细分。

## 验证证据

- 最终**87项隔离XCTest通过，0失败**，含退出调度、文件诊断、原文件快捷键与窗口批次恢复逻辑；实际生产/测试文件12份原样复制并比对SHA-256。诊断门禁从生产文件精确提取，保存提取内容和源文件哈希。
- 完整build-for-testing与Analyze通过，未启动真实App测试宿主、未修改用户偏好。
- 独立无UI进程编入实际生产调度器：旧入口在400ms嵌套等待期间MainActor Task未开始；新入口先返回原回调，约12ms完成Task及异步续跑。2秒内部/5秒外部限制；未创建NSApplication、未发输入或信号。该结果验证调度机制，**不是完整WE1/AppKit退出验收**。
- 独立审查复核删除保护、诊断隐私及退出并发/取消重试。首轮86项测试之后补充诊断分类，以最终87项结果为准，不重复累计6项调度单独测试。
- 证据：`build/ShortcutStability/logic-tests-final.log`、`build-final.log`、`analyze-final.log`、`LogicTests/source-hashes.json`、`TerminationProbe/comparison.json`。初次探测的SDK类型错误和不适用的main queue-specific判定保留，不计为成功证据。

## 状态和后续验证

- 源码修复与诊断准备完成；本轮未安装到Applications，092348继续运行。
- 首次桌面提示仍需新诊断版实际触发记录后判断；不能根据猜测调整删除条件。
- 完整AppKit退出、退出取消后的再次请求仍需候选安装后的独立验证；本轮没有操作用户窗口来制造待恢复批次。
- 正式版AutoUpdater的异步退出入口仅列为其他路径的潜在审查项，没有证据证明其出现同一故障，本轮未扩改。

## 已打包候选

- 候选构建 `20260918105549`，稳定签名 `SuperIsland WE1 Debug Local Code Signing`，签名验证通过。仅生成到 `build/WE1-Debug/SuperIsland-WE1-Debug.app`，未启动/安装。
- 源代码载荷 `836dfddfa224586ca17fb276f61ebbba1ad8bf36b72335bfc852921d36be079b`，101项文件/链接/权限清单保存在 `build/ShortcutStability/candidate-manifest.json`；打包日志 `package.log`。原打包产物自动转存backups，原Applications安装没有变化。
