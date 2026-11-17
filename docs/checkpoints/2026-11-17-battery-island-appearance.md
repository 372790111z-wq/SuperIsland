# 岛内电池面板浅色宿主配色修正

- 用户在本机 20261117151038 提供截图：电池文字几乎不可见，充电上限为黑色文字，蓝色开关和橙色提示仍可见。
- 根因：岛体背景固定黑色，而 BatteryManagementPanel 使用语义前景色且未设定深色环境。系统浅色环境会使该面板文字和原生控件使用浅色主题颜色。此缺陷在此前版本也存在，不能仅因菜单图标更新后发现就认定由显示开关引入。
- 修复范围仅 BatteryManagementPanel 视图边界增加深色 colorScheme。共享 BatterySimpleProtectionView 与设置页不设定强制主题，不修改系统主题、图标开关、充放电策略或权限。
- 新增真实原生宿主 light/dark 对照测试。修复前浅色宿主亮色中性像素 3268，深色宿主 14101，测试失败并生成与截图一致的黑字黑底画面；修复后同一测试通过，人工查看浅色宿主截图已恢复电量、标题、状态、滑杆与设置入口。
- build/BatteryAppearanceBefore.xcresult：1 项失败，证明回归能捕获原缺陷；build/BatteryAppearanceAfter.xcresult：38 项通过、0 失败（BatterySimpleProtectionTests 20、FeatureMasterSwitchTests 18）。全部使用隔离偏好和模拟电池 transport，未向真实 helper 发控制请求。
- 原先界面测试强制 preferredColorScheme(.dark)，掩盖了浅色宿主问题；新测试不再强制宿主为深色，而分别传入真实浅/深环境并检查固定黑色面板的文字可读性。
- 需求语义和布局不变，沿用 BM1 简化面板及现有标注；没有制造新的交互版本或修改历史标注全文。
- 修复构建与安装证据保存于 build/BatteryAppearanceInstall.noindex；用户最终验收另行记录。
