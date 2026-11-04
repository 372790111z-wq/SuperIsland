# 统一版暂停刷新修复 · 2026-11-04

当前结论（16:30更新）：固定包20261104151840的一次82%充电中暂停及恢复充电已实测通过；单次票据已消耗，不重复切换。此次只补App启动生命周期，helper及硬件路径保持原样。以下14:49/14:53为修复前失败证据，不能与16:21后的通过结果混为同一次测试。

范围：已确认需求的实现修正。保留原有电池模块、设置入口和标注ID；不新增图标或页面。普通发行版不启用供电切换。统一WE1本地包可显式封印用户已授权的一次79–85%试验；它不是日常自动刷新策略，也不代表物理验收已通过。

## 本轮实测事实

安装构建20261104114803，代码0a0c019，WE1独立后台启动身份已核对。85→80目标放电到点自动结束；回执targetReached，operation8E16DE2C-42BD-4A52-B022-0CAA4EDD2D4E。14:49的新电池UpdateTime1793774950显示80%、0mA、接电，输入34207mW等于系统负载。

随后临时85建立80%正充电，点击暂停后saved80但registered85持续90秒，最后故障A41F1590-B0A2-422C-8145-140692339820并完成恢复。应用长期值回80、主控off，系统恢复基线85；不能将此恢复说成80限充正在工作。之后只读观察为电池供电，未执行CHIE脉冲。

原始证据位于本checkout的build/unified-delivery/target80-20261104-1443/；completion-report.json、completion-physical.json和pause-failure-restored.json分开记录成功与失败。

## 最小修正

- helper专用BATTERY_PAUSE_REFRESH编译开关、WE1PauseRefreshTrial签名Info标记、WE1客户端同证书白名单三者同时成立，才允许已有单次实现。不会开启全部BATTERY_REVIEW。
- 服务label仍为com.workview.SuperIsland.WE1Debug.BatteryControl；签名/存储标识及pause-refresh-v1.consumed票据路径不变。无票据重置或重试入口。
- 原有79–85、实际正充电、独立适配器输入、已保存目标与实际登记不一致、无校准和其他规则覆盖等准入条件保持。固定8→等待约500ms→0之间无其他读写；间隔不是硬实时保证。
- 报告增加可选pauseRefreshOperationID，仅向实际租约owner返回。App必须同时匹配操作、paused、所有权和无故障，才能表示“已提交、等待验证”，不将available=false直接显示为执行失败。
- 等待验证期间，原暂停按钮变为“取消暂停并恢复”，即使暂时无输入仍可取消。专用取消只release并关闭控制，不自动提交新的控制租约。只有明确无恢复责任才提示恢复完成。取消期间新请求会使旧结果失效，防止覆盖当前状态。
- 打包器要求显式参数与窄编译回执完全一致；拒绝普通包夹带试验、宽Review编译和预先封印的输入包。没有新增第三方依赖。

## 对抗审查与证据边界

独立只读审查检查了门禁、签名客户端、重复消费、恢复链和取消交互。发现并修正外层按钮禁用、pending被当失败、取消等待期间新请求导致陈旧提示等问题。源测试覆盖正负包映射、pending接受与取消、无电源取消、恢复未完成、错误owner/操作/故障以及取消竞态。最终测试/构建/包校验记录在build/unified-delivery/pause-unified/。

静态依据复用同UUID PowerUI缓存反汇编（05E1F9B3-62E9-34DD-B111-6A3DEF44FDAC）：普通defaultschanged调用非强制handleCallback，同SOC可跳过；同值setMCLLimit可早退；enableMCL客户端固定80。80–99先setter可强制回调只是候选，不能覆盖79且有override副作用，本次不混入该路径。留存于原battery-charge-management工作树docs/research/battery-native-control-repair/pause-native-dispatch-20261103/及manual-limit-readback/。

前一离线轮REA对相同AlDente SHA256 bf645423f02f9a9f93f67fd55d213ccb5b043e0286f1bfd3c11b9269f52c80db的PowerUI函数名检索为空（ev_bd72192f8f8559345f3ec77a6303de575e1a4c635fa3375cc46b098e9398ffd5），只说明函数名检索无命中，未推翻留存控制流证据。所开REA会话已关闭；没有启动原程序或调用原helper。

## 单次实机结果及后续边界

安装统一包后，新helper PID494，BTM461E025D-BC77-4CB1-802B-1090942F33C3，kernel/disk CDHash5754fe6563d123dc851b173d936b1855a27a555c；无再次人工批准。16:21:55.991在82%正充电时执行唯一一次8→0，日志间隔0.586268秒。独立输入自动恢复，无人工拔插；pmset登记82，释放后的新UpdateTime1793780576显示82%、电流0、未充电，稳定10秒后验收通过。点击恢复后目标85，新UpdateTime1793780695/0755为83%、正电流2675/2265mA。证据在build/unified-delivery/pause-unified/live/。

随后主控关闭，所有充电偏好与测试前逐字段一致（长期80）；系统原基线85，recoveryPending=false。保存长期80不等于目前正在运行80控制。

准备时还发现WE1 bootstrap早退遗漏service.start：一次UI提交后无心跳，45秒后安全恢复；激活后才启动续约。修复为共同启动生命周期、显式开关先初始化只读生命周期；窗口自激活不再自动开启控制，后台启动不弹设置窗，手动关闭不被后续激活覆盖。增加真实Timer续约与冷关闭回归，helper不变。

单次成功不是任意电量、持续重复暂停或完整校准的验收。票据已经消耗，不删除/改名，不再自动试第二次。新App启动修复的安装和超过45秒的续约检查须单独记录；完整校准、LED物理颜色仍未验收。

## 本轮离线结果

最终全量1956项，3项跳过，0失败；其中2项为既有Kimi延期，1项因当前显示环境没有刘海区域而跳过。新增与现有暂停/cutoff定向43项通过；最终全量包含后补的2项取消竞态测试。打包正负门禁2项通过。独立复审最终无剩余P0/P1/P2发现，仍不构成设备验收。

启动修复最终回归：1958项、2项既有Kimi跳过、0失败；本次内屏可用，刘海布局测试已运行通过。真实Timer续约测试运行15秒并观察第二次renew，冷关闭测试确认后续start(true)不覆盖用户off。独立复审无剩余发现。
