# 独立菜单栏图标显示开关

## 已实现

- 用户确认显示与启用无必然关联并直接授权编码；新增 MB1 需求记录与 20261117 标注版本，保留旧 PRD/版本。
- 挂绳、保持唤醒、电池保护设置页各有独立“显示菜单栏图标”；三项偏好与功能启停、通用主图标开关分离，立即应用并持久保存。
- 现有挂绳和保持唤醒图标无保存值时默认显示；新电池图标默认隐藏。显示偏好观察单独更新表现，不调用原有模块/电源/权限控制流程。
- 图标创建幂等，隐藏释放对应状态项；挂绳 stop 清理自己的状态项，重新启动读取保存偏好。
- 新电池菜单仅展示当前电量及设置入口，复用既有 BatteryManager 更新；无电池隐藏，未知电量使用问号及未知说明，不制造红色 0%。硬件不可用不抹掉用户显示偏好。
- 不修改 macOS 自带电池图标，不发充放电请求，不注册新 helper 或修改权限。

## 验证

- build/FeatureMenuBarVisibilityFinal.xcresult：55 项通过，0 失败。FeatureMasterSwitchTests 18、BatterySimpleProtectionTests 19、KeepAwakeCompletionCompatibilityTests 3、SystemFeedbackTests 15。
- 新增 6 项针对性用例：三个偏好与功能/主图标状态隔离及重载；只观察显示键；保持唤醒四组合和重复显隐；挂绳四组合/隐藏后保持运行/停止重启；电池入口未知/无电池/能力恢复/只读菜单；真实原生显示开关点击联动 NSStatusItem。
- 原生点击使用隔离 UserDefaults、模拟 helper/只读电池快照及临时 NSStatusItem，不切换已安装应用配置。三个开关均分别点击两次，验证偏好、图标增删与功能保持关闭，挂绳系统配置写次数为 0。
- 原生设置页在功能关闭状态下仍展示可用显示开关；640pt 窄页快照检查新增区域无重叠/裁切。原生截图属于测试宿主，不是已安装应用验收。
- 第一轮 35 项中的旧菜单测试仍匹配“接收纯图片剪贴板”，现有菜单早已改为“接收剪贴板图片”；校正陈旧断言后进行上述完整回归，未为了过测试改业务文案。
- annotation 当前指针/index/version 一致；旧 requirements 原样保留；MB1 fullPrdContent 与 PRD 逐字一致；4 个新标注 ID 在源码可定位。三个显示控件已由原生 AX 点击验证，电池状态项通过真实 NSStatusItem 验证。
- 新源文件位于 project.yml 已包含的 SuperIsland 路径；本机忽略的 Xcode 工程同步注册并通过构建，不新增第二套提交中的项目配置。git diff --check 通过。

## 对抗性审查结论与边界

未发现阻断问题。重点检查：显示开关误触功能启停；主图标影响子图标；偏好观察导致重复创建；功能关闭后开关被禁用；隐藏后电量更新重建图标；无电池误显示；未知冒充 0%；设置关闭后无法恢复入口；历史标注被覆盖。

设置仍可从灵动岛设置入口进入；本次不把隐藏等同于退出或卸载功能。macOS 菜单栏空间不足仍可能影响实际可见性，本实现不操控其他 App 的图标位置。不同屏幕/其他机器的最终视觉效果仍待安装后验收。

当前仅本地源码和测试完成，未替换 /Applications/SuperIsland.app，未提交推送或发布。原已验收构建 20261116222813 保持不变。审查记录在 ~/.codex/reviews/20261117-142012-465-independent-feature-menubar-icons.md。

## 本机替换 · 2026-11-17

- 用户明确授权“替换本机我测试”。已审查源码本地提交 f0b30cca98f6480e59848d7c5d68a1fd2320dbf1，Release clean build 通过、前后源码一致。
- 已安装并启动 /Applications/SuperIsland.app，版本 1.0.10 (20261117151038)，保留原 bundle/签名身份。安装包深度签名、解包及应用二进制摘要核验通过。
- 旧版 20261116222813 正常退出后替换，备份位于 build/IndependentMenuIconsInstall.noindex/Installation/Backup/SuperIsland.app，另外保留 Retired 副本。
- 新进程 PID 19120 完成启动并持续观察 30 秒；内核 CDHash 580c468cbef41cbd52939c2f2843fbf4093c2df3 与安装包一致。菜单栏显示偏好、主应用图标及挂绳启用偏好回读保持一致。
- 安装证据：build/IndependentMenuIconsInstall.noindex/Installation/receipt.json。未修改系统权限或 helper 登记，未推送 GitHub 或发布。仍待用户实际测试三个独立开关；启动核验不等于长期稳定或全部设备验收。
