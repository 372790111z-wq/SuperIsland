# 设置窗口动作兼容修复

- 分支：`fix/settings-window-actions-20261022`，基于 Chrome 全屏跨屏已实机验收的 `51e7d6e`。
- 授权：用户指出 SuperIsland 设置页提示“请先选择窗口”、Typeless 提示“系统窗口不支持此操作”，在说明精确开放正式设置窗口、第三方按窗口类型和能力检查后回复“继续”。
- 根因：原实现直接排除自身 PID，并把 accessory 运行模式当作系统窗口；本机 Typeless 同时存在 AXDialog 和可移动、可缩放的非模态 AXStandardWindow。
- 修复：第三方 regular/accessory 应用通过模式筛选后仍检查标准窗口、非模态和 AX 移动/缩放能力；自身只允许 AppDelegate 管理且为 key 的可见正式设置对象，走 AppKit 布局/居中/跨屏，保留全屏过渡、结果回读和失败恢复。
- 边界：不开放自身浮层、权限弹窗、隐藏窗口；自身拖动分屏、关闭及窗口集合动作不在此次范围。窗口最小尺寸优先，半屏容不下时明确提示。Chrome 专用全屏菜单及精确窗口身份路径保持不变。
- 验证：39 项针对性 XCTest 通过（6 项新兼容/坐标/最小尺寸检查，33 项既有全屏及窗口身份回归）；`build/SettingsWindowValidation/tests.log` 和对应 xcresult 留存。
- 需求归档：仅同步用户确认的正式设置窗口例外及 accessory 窗口判定，保留历史版本；20261022 的 WE1 fullPrdContent 与正式 PRD 一致，原界面映射不变。
- 状态：代码及自动测试完成；尚未替换本机 App，真实设置窗口快捷键、Typeless 及 Chrome 新包回归待安装验收，不把测试或打包视作实机通过。
