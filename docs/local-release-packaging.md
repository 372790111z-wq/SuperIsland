# 本机 Release 打包

日常使用的优化版名称统一为 **SuperIsland**，产物为 `SuperIsland.app` 和
`SuperIsland-构建号-arm64.zip`。`scripts/package-local-release.py` 只在新目录生成、
签名并核验安装包，不退出应用、不安装、不更新 LaunchServices、不发布到 GitHub。

保留 `com.workview.SuperIsland.WE1Debug`、现有本机签名证书及指定签名要求，沿用
现有设置、扩展目录和权限身份。内部 WE1 证据键、数据目录和更新协议不是显示名称，
不能全局替换。路径变化后的权限和登录项仍需安装后核验。

`scripts/package-we1-debug.sh` 专门用于带 debug dylib 的开发调试版，仍使用测试名称；
不要用它打包日常使用的 Release。历史包不重命名或覆盖。

## 构建证据与使用

先提交审查后的源码，执行 Release arm64 构建，关闭覆盖率和 debug dylib，保留原
bundle ID。构建前后确认 Git 源码未变；将下面字段写入忽略的 `build/` 目录下的
JSON 回执。回执不是自行填入的通过标志：必须来自实际构建命令的退出码、前后
源码检查及产物 SHA-256。

| 字段 | 实际证据 |
| --- | --- |
| `exitCode` | xcodebuild 退出码，须为 0 |
| `sourceUnchangedDuringBuild` | 构建前后 revision、tree 和干净状态一致 |
| `sourceRevision` / `sourceTree` | 构建时的完整 Git HEAD / tree |
| `sourceRoot` | 本次构建真实 checkout 的绝对路径 |
| `sourceApp` | 本次 Release 的绝对 `.app` 路径 |
| `sourceBinarySHA256` | 该 app 的 `Contents/MacOS/SuperIsland` 哈希 |
| `sourceAppSHA256` | 打包器 `app_digest()` 计算的完整 app 文件、模式与符号链接清单哈希 |

```sh
python3 scripts/package-local-release.py \
  --build-receipt build/LocalRelease.noindex/build-receipt.json \
  --reference-app /Applications/SuperIsland-WE1-Debug.app \
  --output-dir build/LocalRelease.noindex/Package.noindex
```

改名安装完成后，下一次 `--reference-app` 指向 `/Applications/SuperIsland.app`。
参考应用仅用于读取和比较稳定身份，不会修改。输出目录必须不存在。

打包器检查产物架构、测试运行时、覆盖率、签名身份，解包 ZIP 并再次核验；失败时
保留输出供排查，不标记为成功，不修改历史产物。`manifest.json` 明确区分签名、安装
和公证状态。自定义签名使用 `--signing-identity`，但仍必须匹配参考 app 的指定要求。

新本地安装包不自动成为远端更新。现有更新渠道的 `we1-` tag 和
`SuperIsland-WE1-*.dmg` 文件名保持兼容；本次没有发布或迁移远端更新协议。
