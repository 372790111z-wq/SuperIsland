# 岛内电池面板浅色宿主配色修正

- 用户在本机 20261117151038 提供截图：电池文字几乎不可见，充电上限为黑色文字，蓝色开关和橙色提示仍可见。
- 根因：岛体背景固定黑色，而 BatteryManagementPanel 使用语义前景色且未设定深色环境。系统浅色环境会使该面板文字和原生控件使用浅色主题颜色。此缺陷在此前版本也存在，不能仅因菜单图标更新后发现就认定由显示开关引入。
- 修复范围仅 BatteryManagementPanel 视图边界增加深色 colorScheme。共享 BatterySimpleProtectionView 与设置页不设定强制主题，不修改系统主题、图标开关、充放电策略或权限。
- 新增真实原生宿主 light/dark 对照测试。修复前浅色宿主亮色中性像素 3268，深色宿主 14101，测试失败并生成与截图一致的黑字黑底画面；修复后同一测试通过，人工查看浅色宿主截图已恢复电量、标题、状态、滑杆与设置入口。
- build/BatteryAppearanceBefore.xcresult：1 项失败，证明回归能捕获原缺陷；build/BatteryAppearanceAfter.xcresult：38 项通过、0 失败（BatterySimpleProtectionTests 20、FeatureMasterSwitchTests 18）。全部使用隔离偏好和模拟电池 transport，未向真实 helper 发控制请求。
- 原先界面测试强制 preferredColorScheme(.dark)，掩盖了浅色宿主问题；新测试不再强制宿主为深色，而分别传入真实浅/深环境并检查固定黑色面板的文字可读性。
- 需求语义和布局不变，沿用 BM1 简化面板及现有标注；没有制造新的交互版本或修改历史标注全文。
- 修复构建与安装证据保存于 build/BatteryAppearanceInstall.noindex；用户最终验收另行记录。

## 本机试用交付

沿用刚才用户授权的本机替换流程，已安装 1.0.10 (20261117152430)，源码 8fc5fd4a08a2d8845a70468bfc4ad727aa77f2fd。旧包 20261117151038 正常退出并备份。PID 29885 完成启动，持续观察30秒且内核CDHash匹配签名包。尚未推送发布，用户实际显示确认待完成。

## 用户确认与发布产物

用户确认“可以了”，并明确要求同步 GitHub、发布安装包。发布复用构建20261117152430的原签名ZIP，SHA-256为f720b8e5f364bdb0fb678f5f59c3fcfd5c3ad9a98241623ecede1f2b712e76e0。tag superisland-20261117152430-test精确指向源码8fc5fd4；main后续为验收记录。沿用Apple Silicon/macOS14+、本机签名未公证prerelease，不改变自动更新渠道。最终发布状态以Release与外部审查回读为准，本机确认不扩展为所有设备验收。
