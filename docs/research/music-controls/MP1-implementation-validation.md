# MP1 原生实施与验证记录

日期：2026-11-09。分支：`feat/music-hover-half-expanded-20261109`，基线：`c1faef9`。

## 授权与交付边界

用户已确认 HTML、正式 PRD，并明确“确认，开始编码”。QQ 临时测试另获“允许临时测试并恢复原状态”授权。当前完成本地源码、Debug 构建、针对性测试及 QQ 11.10.5 实际操作验证；**未替换现有安装、未提交或推送 GitHub、未发布新包，安装后的整体实机验收尚未完成**。

需求真源：[MP1 PRD](../../product-package/11-SuperIsland音乐悬停与播放器能力PRD-MP1.md)。HTML v0.1 冻结；标注版本 `20261109`。

## 实现

- `AppState.swift`：沿用现有悬停延迟及通知/扩展/拖动/输入门禁，在可展示音乐且播放中时进入半展开；已显示的音乐横条保持半展开；暂停后收起再进入保留原全展开路径。新增音乐状态读取依赖用于隔离实时时钟与播放器数据的状态转换测试。
- `NowPlayingExpandedView.swift`、`IslandContainerView.swift`：标题和空白独立展开，封面复用来源打开组件，增加上下曲；子控件不通过父表面 tap 全展开。横条根据高级能力调整高度。
- `HomeScreenView.swift`：现有全展开实际展示首页音乐卡片，因此同步接入相同高级按钮与状态，避免仅修改未使用的旧 fullView。
- `NowPlayingAdvancedControls.swift`：统一能力与三态收藏、三种模式；按进程/启动时间/曲目快照绑定请求；单在途操作、取消栅栏、迟到回调丢弃、可见性驱动读取；模块关闭和退出清理。
- `QQMusicControlAdapter.swift`：限定 QQ 11.10.5，读取 `QQMianWindow` 的直接“播放控制栏”，精确匹配当前歌曲名与歌手。写入通过“播放控制”菜单的标准 AXPress，模式选择具名目标；没有固定坐标、没有遍历推荐列表、没有账号凭据或网络私有写入。
- QQ 收藏未选中标签为“添加到我喜欢”，已选中为“从我喜欢删除”；菜单分别为“喜欢歌曲”/“取消喜欢”。这些反向标签来自本轮授权实测。QQ 栏位会先更新、菜单稍晚更新，因此回读同时等待目标状态和对应菜单可用；超时不自动重发。
- `MusicAdvancedButtons.swift`：两处界面共用收藏/模式状态，未知禁用，状态说明和“重读”用于恢复；只读取，不自动重复原动作。

## 已验证

| 验证 | 结果与证据 |
| --- | --- |
| 原生 Debug 构建 | 通过；使用现有 Aptabase 锁定版本和本机缓存，没有升级依赖。首次缺少生成工程内 Package.resolved，复制已有锁文件后解决。 |
| XCTest | 最终 43 项全部通过：MusicHoverPolicyTests 3、MusicAdvancedControlsTests 4、MusicHoverTransitionTests 1、MusicNativeRenderingTests 1、NowPlayingSourceOpenerTests 24、WindowDragHoverGateTests 10。日志 `/tmp/mp1-tests-final.log`；xcresult 在 `build/MP1Derived/Logs/Test/`。 |
| 悬停状态转换 | 通过实际 AppState 悬停计时入口测试，媒体快照注入隔离真实播放器更新；覆盖播放悬停半展开、暂停再进入已展开横条不升级、点击全展开、收起后的暂停悬停走原路径。此项不是已安装 App 的鼠标实测。 |
| 原生视图 | NSHostingView 渲染实际 QQ 来源横条 408×134；截图 `build/music-hover-native/mp1-native-preview.png` 已查看，歌曲信息、封面、六个按钮和状态提示可见；原生事件验证禁用收藏不升级，标题点击进入全展开。 |
| 权限降级 | 无辅助功能权限的测试宿主实际显示未知并禁用高级控制，提示检查系统设置；不会假装未收藏。 |
| QQ 实际写入 | 使用同一适配器源码通过 Swift 执行器连接实际 QQ 11.10.5。收藏 true、取消 false、单曲循环、随机、顺序均回读成功，最终恢复未收藏和顺序播放。日志 `build/music-hover-native/mp1-qq-native-validation.log` 不含歌曲/账号信息。 |
| 后台只读 | QQ 非前台、主窗口保留时读取成功，收藏和模式能力均可用。见 `build/music-hover-native/mp1-qq-background-read.log`。没有额外发出写入。 |
| 窗口缺失 | 调查时两次观察到 QQ AX windows=0，探测程序停止且未发送动作；之后窗口已恢复，未强行关闭用户窗口，因此适配器完整窗口缺失回归仍待。 |
| 标注归档 | 新建 `20261109.json`，7 个语义 ID 在原生源码存在，fullPrdContent 与 PRD 逐字一致，index/current/version 指针一致，原 9 个 requirements 原样保留。原生标注 ID 的全量运行时树命中未独立验收。 |

最初的 80ms 状态转换测试受首次运行初始化和真实媒体异步更新影响而失败；改为注入确定的媒体快照并等待有界状态转换，生产悬停延迟仍取用户设置。测试宿主中的系统 linkd/helper 环境日志不是上述业务断言失败；最终测试 0 failures。

## 可用性与剩余验证

已查看原生截图：保持音乐信息与操作在同一横条，封面及标题职责明确；权限缺失有说明，未知状态不画成未收藏；“重读”仅刷新状态，不重复写入。全展开音乐卡片复用相同协调器。QQ 的布局比基础来源多出状态区域，未改变其他模块尺寸。

仍待安装后验证：真实灵动岛鼠标悬停/移出、基础上下曲/暂停/seek 的播放器响应与不冒泡、封面打开来源、全展开首页的完整视觉布局、刘海/外接屏、通知抢占及其他模块回归。真实未登录、网络断开、QQ 其他版本及窗口缺失恢复未全量测试；当前版本之外明确降级，不声称跨版本通用。收藏写入及模式已验证的是实际 QQ 适配链路，尚不能等同于新安装 App 的整体验收。

## 同步与回滚

所有修改仅位于当前独立 worktree。旧安装及主仓库不变。无依赖/权限升级；没有改 QQ 客户端文件。可按本报告涉及文件逐项撤回，本地调试构建在忽略的 `build/` 内；历史 annotation 文件未覆盖。临时 QQ 测试已恢复原状态；新曲目的状态不会用旧快照覆盖。
