# Dock 增强视觉 QA

## 对照基准

- source visual truth path: `prototype/assets/dock-visual-reference.png`
- implementation screenshot path: `prototype/assets/dock-implementation-final.png`
- focused implementation path: `prototype/assets/dock-implementation-desktop-final.png`
- side-by-side comparison path: `prototype/assets/dock-qa-comparison-final.png`
- viewport: 1280 × 720 CSS px
- source pixels: 1342 × 848，源图按容器等比缩放
- implementation pixels: 1280 × 720；聚焦桌面区域 676 × 423
- device scale factor: 浏览器默认值；比较板对两张图分别等比缩放，不做拉伸
- state: Dock 增强 / 备忘录单窗口 / 正常缩略图权限

## 最终对照结论

全景和聚焦区域均已对照。参考图的目标组件是“锚定 Dock 图标的紧凑暗色毛玻璃预览卡”，不是整张桌面壁纸或 Calendar 内容；实现保留 SuperIsland 自己的桌面、窗口和应用内容。

- 字体与排版：使用 macOS 系统字体栈；应用名位于卡片顶部，窗口名位于缩略图底部，与参考层级一致。
- 间距与布局：卡片与当前 Dock 图标中心对齐；箭头落在图标上方；单窗口卡 170 × 158，图标悬停约 61 × 61，比例由首轮 4.3 倍收敛到约 2.8 倍。
- 颜色与材质：暗色半透明背景、细亮边框、圆角、背景模糊和内高光与参考方向一致。
- 图像质量与素材：Dock 使用本机真实 macOS 应用图标 PNG；缩略图展示当前原型窗口内容，不使用文字或 emoji 代替应用图标。
- 文案与内容：参考图中的 Calendar 替换为 SuperIsland 演示中的备忘录/Safari/音乐；这是产品内容差异，不是视觉漂移。

## 交互与状态验证

- 单窗口：浮层锚定备忘录图标，缩略图和标题可见。
- 多窗口：Safari 显示 2 张横向窗口卡，浮层宽度自适应为 326 px，并继续锚定 Safari 图标。
- 权限降级：屏幕录制未授权时保留同一浮层外壳，显示“标题模式”和窗口标题，不影响入口。
- 页面布局：当前 1280 × 720 视口无横向溢出，浮层未越出桌面区域。
- 控制台：未发现页面 error 或 warn。

## 比较历史

1. 首轮发现 P1：旧稿为居中宽浮层、文字占位 Dock 图标，视觉结构与参考图不同。
   - 修复：改为图标锚定、暗色毛玻璃卡片、真实应用图标、顶部应用名和底部窗口名。
2. 第二轮发现 P2：卡片与 Dock 图标比例仍偏大，且默认进入未授权降级态。
   - 修复：放大 Dock 图标、收窄单窗口卡；默认展示正常缩略图，未授权状态移入状态实验室。
3. 最终并排对照未发现仍需处理的 P0/P1/P2。剩余差异仅为 SuperIsland 自身桌面内容和参考图 Calendar 内容不同，属于有意保留。

## Follow-up Polish

- P3：Swift 实现阶段可依据真实 NSVisualEffectView 材质，对模糊半径和边框亮度做设备级微调。

final result: passed

---

# SuperIsland 窗口增强设置适配 QA

## 对照基准

- SuperIsland source of truth: `SuperIsland/Settings/SettingsView.swift`
- Wins 主设置参考: `prototype/assets/wins-settings-visual-reference.png`
- Wins 快捷功能参考: `prototype/assets/wins-quick-functions-reference.png`
- Wins 窗口布局参考: `prototype/assets/wins-window-layouts-reference.png`
- Wins 高级选项参考: `prototype/assets/wins-advanced-reference.png`
- SuperIsland 设置首屏: `prototype/assets/settings-superisland-shell-final.jpg`
- 快捷功能悬停态: `prototype/assets/settings-superisland-quick-hover-final.jpg`
- 快捷功能并排对照: `prototype/assets/settings-superisland-quick-comparison-final.jpg`
- 布局快捷键实现: `prototype/assets/settings-superisland-layout-shortcuts-final.jpg`
- 布局快捷键并排对照: `prototype/assets/settings-superisland-layout-comparison-final.jpg`
- 高级选项实现: `prototype/assets/settings-superisland-advanced-final.jpg`
- 高级选项并排对照: `prototype/assets/settings-superisland-advanced-comparison-final.jpg`
- browser viewport: 896 × 782 CSS px
- reference pixels: 1322 × 1146；implementation pixels: 896 × 782

## 最终对照结论

本轮纠正了错误产品外壳：Wins 的 macOS 系统设置容器不再作为实现目标。实现以 SuperIsland 当前 Swift 设置源码为真源，恢复 960 × 680 深色独立窗口、200 px 侧栏、#1C1C1C 背景、#2A2A2A 分组卡和 #333 选中态，并在现有“通用 / 模块 / 外观 / 扩展 / 高级”之间新增“窗口增强”。

Wins 的参考只用于右侧内容和交互：顶部七项能力、调度中心 Pro、快捷功能、窗口布局、开关和快捷键胶囊保留其信息层级；产品名称、功能说明、权限边界与整体视觉继续属于 SuperIsland。

- 信息层级：调度中心、快捷功能、窗口布局的顺序与 Wins 参考一致。
- 快捷功能：Dock 锁定屏幕、隐藏所有窗口、隐藏其他窗口、上下显示器移动、窗口居中六项均已补齐。
- 窗口布局：按参考扩展为 10 种布局，每种布局都有独立快捷键录入按钮，不再把布局图当成执行按钮。
- 高级选项：保留预留台前调度空间、分屏窗口间距、强调色、排除 App、关于和完成；按用户要求删除授权、试用、购买和激活。
- 联动方式：左侧演示区在内容滚动时保持可见；右侧任一能力被鼠标移入或键盘聚焦时切换对应视频、标题与说明。
- 品牌与材质：使用项目真实 SuperIsland App 图标和现有深色设置色值；未伪造系统设置图标或浅色外壳。
- 边界：HTML 只确认结构与交互，不代表快捷键、辅助功能权限或真实窗口控制已经接入 Swift。

## 交互与状态验证

- 核心七项、调度中心两项和快捷功能六项均有独立 `data-preview` 映射。
- 快捷功能六段视频均达到 `readyState=4`，处于播放状态，标题与素材源一一匹配。
- 调度中心“关闭窗口 / 退出程序”两段视频均达到 `readyState=4` 并正常播放。
- “隐藏所有窗口”开关关闭后 `aria-pressed=false`，演示仍保持“隐藏所有窗口”，验证开关与预览互不干扰。
- 左半屏布局已实际录入 `⌘ ⇧ L`；快捷键录入后退出记录态并显示组合键。
- 高级选项可打开和完成返回；强调色选择更新 `aria-pressed`，排除 App 可加入 Finder 演示项。
- 高级选项 DOM 与截图均不包含“授权信息”“购买”或“激活”。
- 最终浏览器控制台无 error 或 warn。

## 对抗式复核

1. 错误候选：1:1 复制 Wins 所在的 macOS 系统设置外壳。
   - 结论：与 SuperIsland 现有独立设置窗口冲突，已经彻底移除。
2. 容易产生的假完成：只有顶部七项悬停演示，快捷功能只是静态行。
   - 结论：已补齐调度中心、六项快捷功能，并将窗口布局扩展为 10 个独立快捷键入口。
3. 容易产生的状态漂移：点击开关同时改变或停止演示。
   - 结论：预览和开关事件独立，浏览器回归已验证。
4. 当前非目标：修改 PRD 或 Swift 设置页。
   - 结论：本轮只修改 HTML、参考素材和 QA 证据，未进入后续 Gate。
5. 错误候选：照搬 Wins 的授权、购买和激活信息。
   - 结论：商业化信息不属于当前 SuperIsland 需求，已按用户反馈移除。

## Follow-up Polish

- P3：进入 Swift 实现前，为“窗口增强”侧栏项选择正式 SF Symbol，并把参考视频替换为 SuperIsland 自有录屏或实时演示。

final result: passed
