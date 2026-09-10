# WE1 性能优化前基线 · 2026-09-10

## 保存目的和范围

用户确认先保存当前工作，再创建性能优化分支，保护已经验证的行为。本次只整理和保存基线，没有修改 Swift 实现、重新构建、安装、推送或进行新一轮产品验收。

- 原目录：`/Users/muyz/Projects/new super island/SuperIsland`，保留修复分支 `fix/we1-window-inventory-gate-20260907`。
- 新分支：`perf/we1-preview-latency`；独立目录：`/Users/muyz/Projects/new super island/worktrees/we1-preview-latency`。创建时与本次基线提交完全相同。
- 纳入现有 6 个源码/测试修改、PROGRESS/BLOCKED、原始 WE1 PRD 和现有 prototype 资料。原始 PRD 中的分支和 Gate 是需求建立时的历史记录，不是性能优化的新方案。
- `prototype/assets/settings-previews` 的 20 个文件和 `settings-layouts` 的 14 个文件由 `project.yml` 直接引用，必须随源码保存。其余原型与参考图片一并本地存档；第三方参考资料的本地保存不代表可以随产品公开发布。
- `default.profraw` 是运行时覆盖率产物，保留在原目录但不提交。构建产物、应用包、用户 Xcode 状态、权限、签名凭据和外部诊断原始数据不入 Git。

## 验证依据与实际边界

6 个源码/测试文件的 SHA256 全部匹配外部证据目录 `zcode-closed-preview/final-source-verification.json` 的 current 值。最终成功测试日志是 `logs/reviewed-tests.log`：107 项 inventory 测试、48 项 interaction 测试，共 155 项通过、0 失败。`logs/final-tests.log` 是中间失败日志，不能作为成功依据。本次只验证源码仍与成功证据一致，没有重新运行测试。

用户已确认的历史场景包括 Ego/普通微信 Dock 完整性与归属，Chrome 同安装路径共享列表及记录中的点击、关闭、最小化和全屏恢复，以及 ZCode 关闭后旧卡消失。验收仅覆盖各次实际记录的场景。

尚未解决或验收：主微信主窗口像素不可用；两套微信 Cmd-Tab 无卡；其他尚未识别的缺预览应用；原始启动窗口退休的连续过程；更广的 Space/多显示器覆盖；冷启动、热切换、长时间运行的实际性能。

本次存档前读到的已安装 WE1 为 **20260910120616**。原应用保持运行，不因建立 worktree 更换安装包。历史 PID 不用来标识持久版本。

## WINS 对比结论与后续方向

这是已有只读调研结果及候选方向，不是已实施功能或已确认的性能 PRD。

- 当前 WE1 首次展示会等待候选窗口整批捕获；正常路径主要先做新捕获，现有图片缓存更多用于失败回退。候选方向是先显示身份及生命周期仍有效的缓存，再逐卡更新。
- 当前 Dock 目标切换存在 280ms 等待；Cmd-Tab 鼠标更新以 45ms 合并。候选方向是区分首次悬停与预览已经打开后的目标切换，保留最新目标校验。
- AX 窗口读取和不同消费者的捕获存在重复。候选方向是共享同一轮窗口快照与捕获任务，同时保留关闭退休、进程生命周期、所有权和权限失效检查。
- WINS 本机二进制可见 20ms 鼠标节流、专用悬停队列、缓存 AX 路径、常驻窗口模型和视图复用。其显示路径会在展示前同步调用单窗口直接捕获；不能据此声称 WINS 已经采用异步渐进预览。
- 目前没有可支持首帧延迟或 P95 数字的实测。后续需分别记录冷启动、热切换、A→B→A 的首张有效预览和切换耗时；不能用 Debug/Release 差异代替实际测量。

主微信取图问题与原生 Cmd-Tab 多开身份问题相互独立。不得通过放宽跨安装路径归属或复用已退休窗口缓存来换取速度。此前额外实例选择步骤未获接受。

## 本地恢复输入

保存目录：`/Users/muyz/Projects/new super island/.codex-audit/checkpoints/we1-20260910-before-preview-performance/`。其中 README 和完成清单记录实际提交 ID、工作树路径、归档校验与恢复方式。旧进展文档的原始版本在 before-overlay 中保留。

生成的 `SuperIsland.xcodeproj` 被仓库忽略规则排除；本次单独保存并复制 3 个不含用户态的文件到新 worktree：`project.pbxproj`、`project.xcworkspace/contents.xcworkspacedata`、`project.xcworkspace/xcshareddata/swiftpm/Package.resolved`。依赖锁为 Aptabase 0.3.11 / cfd67fac2a228d448d9d2ac92ffc71589cc3ef00。没有复制 xcuserdata，也没有安装依赖。

外部验证证据原路径：`/Users/muyz/Projects/new super island/.codex-audit/wins/2026-09-10/zcode-closed-preview/`。这些本机证据及工具链不会自动随 Git 克隆迁移；新设备重建时应检查它们的可用性。
