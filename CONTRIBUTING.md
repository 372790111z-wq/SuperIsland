# 参与 SuperIsland 维护

## 获取当前代码

本仓库是 `372790111z-wq/SuperIsland`。请从 [README](README.md) 所列的当前维护分支创建工作分支，避免从尚未包含后续功能的 `main` 开始。

```sh
git clone --branch fix/we1-codex-usage-refresh-20260921 https://github.com/372790111z-wq/SuperIsland.git
cd SuperIsland
git switch -c your-feature
```

构建依赖、provider 准备和本机签名步骤见 [构建说明](docs/RELEASE.md)。不要直接运行上游发行脚本覆盖已安装应用。

## 修改与验证

- 一次提交围绕一个具体问题；保留已有未提交工作。
- 窗口、Dock、Cmd-Tab 和拖放改动应验证真实入口，不以设置开关或提示代替操作结果。
- 仅文档改动检查内容和链接；行为改动运行相关测试，并记录测试环境及未覆盖边界。
- 改动用户可见功能时，同步更新操作文档、版本记录和必要的真实截图。截图移除私人信息，不把设计原型当实机结果。
- 不提交 app/DMG/ZIP 构建包、缓存、登录态、凭据、私人文件、完整用户日志或依赖目录。
- 新模块遵循现有 Manager、CompactView、ExpandedView 结构；扩展开发参见 [EXTENSIONS.md](EXTENSIONS.md) 与 [EXTENSIONS-API.md](EXTENSIONS-API.md)。

## 代码审查

PR 应以包含当前工作基础的维护分支为目标，说明具体问题、行为变化和验证结果。合并到 `main`、改变更新渠道和公开发行另行审查；推送分支不代表完成这些步骤。

Swift 与 JavaScript 风格遵循现有模块。界面代码遵守主线程约束；诊断日志不得包含凭据、账号标识或私人正文。

## 报告问题

请在 [本仓库 Issues](https://github.com/372790111z-wq/SuperIsland/issues) 提供：

- 应用构建号、macOS 版本、显示器数量；
- 具体入口和可重复步骤；
- 预期与实际结果，必要时附去除私人信息后的截图。

涉及发行、签名、公证或 Homebrew 的改动，应同时更新 [docs/RELEASE.md](docs/RELEASE.md)，明确哪些产物实际验证过。
