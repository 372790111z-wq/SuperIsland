# WE1 恢复原有高级与扩展

## 范围与基线

用户纠正：高级和扩展已经在原 SuperIsland 中实现，当前任务是恢复使用并适配 WE1。沿用既有原生页面及中文化 PRD，不再实施 `prototype/we1-local-settings-v0.1.html` 中的分阶段、仅番茄钟开放方案；该 HTML 仅是被本次决定替代的早期提案。

基线为 `f6ebbf2`、已安装构建 `20260920160408`，回退标签 `we1-160408-optimized-installed-20260920`。实施分支 `fix/we1-restore-original-settings-20260920`。本次未修改窗口预览、Cmd-Tab、Dock 点击和分屏算法。

## 实际恢复

- 高级页移除整页禁用：显示器选择、能耗诊断、重置、版本与更新可用。重置只清除当前应用域，并同步现存窗口设置对象；先停止扩展与待完成登录，再恢复默认状态。
- 六个原有扩展入口恢复：番茄钟、AI 用量、Agents Status、WhatsApp、Linear、Last.fm。WE1 首次默认关闭，用户主动启用后保留选择。只发现本应用安装及内置目录。
- Linear/Last.fm 使用本次启动的原生授权会话接收回调，WE1 不注册原版 `superisland://` 全局处理器。取消或回调错误不覆盖已有登录。
- WhatsApp 使用 WE1 独立登录、头像缓存路径；浏览未启用扩展不会启动服务。运行文件从既有锁定依赖构建，包内含依赖版权声明；本机使用已存在的 Node。退出、停用、重载隔离旧进程和排队回调。
- Agent 后台只管理本次启动的进程，首次不安装或卸载用户 CLI hooks；用户可通过原设置主动启用。其他进程占用端口时报告冲突，不接管或终止它。
- WE1 更新检查使用用户仓库；当前公开发布列表为空，显示“暂无适用更新”。下载后核对应用 ID、构建号、架构及当前签名身份，暂存校验后替换，并保留回退副本。原版继续使用原发布源。

## 已执行验证

- 完整 XCTest：首轮 501 项通过；修复复查发现的 WhatsApp 生命周期问题后，最终 502 项通过，零失败。
- Agents Status：4 项 JS 激活测试、5 项 Python 测试通过；测试未修改用户 CLI 配置。
- WhatsApp 打包：锁定依赖、禁用安装脚本；离开 node_modules 后启动输出 ready，空输入后正常退出，没有建立登录目录或连接账号。
- 保留 `app-localization-settings-ui` 和 `app-localization-extension-ui` 原标注映射；没有新建并行需求真源。
- 原生安装与交互结果在安装记录补充；上述源码测试不能代替账号登录及第三方服务验收。

本机证据：`build/WE1RestoredSettings.noindex/` 下 `tests-final.log`、`RestorationFinalTests.xcresult`、`PreparedProviderV2/build.json`。构建产物、权限、账号和签名私钥不提交 Git。

## 构建与发布约定

WE1 构建前运行 `scripts/prepare-we1-whatsapp-provider.py --esbuild <现有 esbuild 0.27.7> --output-dir <新的构建目录>`；构建设置 `WE1_WHATSAPP_PROVIDER_DIR` 指向该目录。构建校验源码、锁文件与打包产物哈希，缺少或过期时明确失败。

未来适用更新使用 `we1-YYYYMMDDHHMMSS` 标签及 `SuperIsland-WE1-YYYYMMDDHHMMSS-arm64.dmg`（或 x86_64/universal）资产；这是本次更新筛选规则，不代表已经存在或发布该资产。没有上传、创建 Release 或更改远端状态。

## 仍需真实账号验证

Linear/Last.fm 完整授权、WhatsApp 手机扫码与消息同步、AI 用量真实账号、Agents CLI 集成需由用户主动启用并登录后验证。本次不会自动读取原版登录或写入全局 CLI 配置，也不把解析器、服务启动测试等同于这些集成已验收。
