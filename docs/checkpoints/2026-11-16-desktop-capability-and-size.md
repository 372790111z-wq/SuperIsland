# 无内置电池设备与无刘海尺寸修正

用户报告 Mac mini 展开后电池菜单按钮变红，收起时调整外观尺寸无反应，并要求无电池/无机盖设备不再出现不适用的提示。

## 证据和实现

- 基线307a619，隔离分支feat/battery-simple-20261116；未动原主仓现场。
- 原电池菜单只检查默认整数0，没有判断内置电池是否存在；无刘海紧凑content和shell使用固定220×28，忽略外观设置。
- BatteryPresence独立区分存在、不存在、未知。成功查询且无内置电池才归为不存在，UPS不计入内置电池；查询失败/描述缺失保持未知；有AppleSmartBattery硬件但电源列表暂缺也保持未知。
- 确认无电池时隐藏展开栏电池按钮、从可用模块中过滤；直接进入电池设置显示中性不适用说明。若仍有恢复责任则保留恢复入口，不因隐藏UI丢弃安全义务。
- 有电池但容量缺失/无效显示未知，不再用0表示；真实0%仍保留低电量表现。未知读数不写入电量历史，未知颜色中性。
- 无机盖设备隐藏保持唤醒设置的合盖描述、状态和菜单合盖回顾入口；普通保持和屏幕控制继续保留。不是按Mac mini型号特判。
- 无刘海紧凑内容、外壳与窗口尺寸使用同一用户配置，外接屏幕同样适用；保留刘海最小值与正常尺寸边界；说明文案明确只调整收起状态。

## 验证及反向审查

- build/DesktopCapabilitiesFinal.xcresult：26项通过，0失败。SystemFeedbackTests 14项、KeepAwakeCompletionCompatibilityTests 3项、BatterySimpleProtectionTests 5项、NotificationRoutingTests 4项。
- 覆盖无刘海宽高变化、外壳与真实窗口尺寸计算一致、音量亮度尺寸稳定、尺寸边界；无电池/UPS/读数失败/临时缺失/真实0%与归一化。
- 原生NSHostingView与菜单注入桌面能力，核验不显示合盖/开盖提示并保留任务结果说明。第一次测试宿主缺少完整AX树导致旧说明ID检查失败，显式启用宿主AX展示后重跑通过，未把空树当作控件不存在。
- 保留原需求与历史归档，按BM1-S01无电池边界及KA1桌面能力约束修正实现；现有si.bm.simple、si.ka.status/menu标识沿用，没有改PRD或制造新设计版本。
- 没有改变电池控制、机盖内核控制、系统权限或通知合成策略；没有修改用户已保存的模块开关。
- 用户家中Mac mini未直接连接或实测。上述能力注入不等于该机器验收；当前未安装本机、未发布GitHub。修改保存在隔离worktree，可按文件差异恢复基线，不影响已发布20261116183302。

## 安装阶段发现的所有权错误及修复

- 候选 20261116222334 启动崩溃，符号化定位 BatteryManager.updateBatteryInfo。此前改造误把 IOPSGetPowerSourceDescription 的借用返回值用 takeRetainedValue 接收；SDK 说明该字典由 snapshot 持有、调用者不得释放。
- 改为 takeUnretainedValue，并提取只读 readDescriptions 供生产与真实 IOPS 回归共用。原始两处 Copy API 仍使用 takeRetainedValue。
- build/BatterySnapshotOwnership.xcresult：15 项通过，包含连续保留 100 份真实电源快照后访问字典；另以 swiftc -O 独立运行生产读取函数，1000 份实际快照可正常访问。此前纯字典能力测试没有覆盖系统 CF 所有权，不能代替此验证。
- 失败候选已退出并恢复 20261116183302；修正版重新构建安装结果以本机安装回执为准。
