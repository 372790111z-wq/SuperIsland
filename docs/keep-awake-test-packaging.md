# 原生保持唤醒跨机测试包

`scripts/package-keep-awake-test.py` 为已提交、已核验的构建生成独立测试 ZIP。
它不依赖 `/Applications` 的参考 App，不安装、不启动、不注册辅助程序，不下载运行时、
不创建或导出签名私钥，也不移除隔离属性或改变 Gatekeeper 设置。

本入口用于原生保持唤醒跨机测试，不是已公证的正式发行流程，也不表示所有 JavaScript
扩展已具备跨机运行条件。用户接收测试包后无需 Python、Xcode 或 Homebrew 来运行原生功能；
制作测试包的构建机需要已有 Xcode 命令工具、Python 3.9+ 和可用的证书签名身份。

```sh
python3 scripts/package-keep-awake-test.py \
  --build-receipt build/KeepAwakeTest/build-receipt.json \
  --signing-identity '已存在的测试签名证书名称或指纹' \
  --architecture arm64 \
  --output-dir build/KeepAwakeTest/Package.noindex
```

也接受 `--architecture x86_64`；必须提供实际构建出的对应架构，不能把 arm64 包改名成 Intel 包。
可用 `--build-number YYYYMMDDHHMMSS` 指定测试构建号；默认使用打包时间。输出目录必须不存在。
签名身份必须包含证书，不能使用 ad-hoc `-`。证书私钥保留在构建机原有 Keychain 中。

构建回执沿用 [本机打包回执](local-release-packaging.md) 的真实字段：
`exitCode`、`sourceUnchangedDuringBuild`、`sourceRevision`、`sourceTree`、`sourceRoot`、
`sourceApp`、`sourceBinarySHA256`、`sourceAppSHA256`。回执必须来自真实成功构建，
与当前干净 checkout 的 revision/tree、实际源 App 及资源、模式和符号链接摘要一致；不能手写通过标志。
本工具复用现有 `app_digest()`，没有建立第二种构建摘要算法。

主 App 保留回执绑定的 Info.plist bundle ID，不强制改成开发 ID。当前 helper 契约仅接受
`com.workview.SuperIsland` 和 `com.workview.SuperIsland.WE1Debug`；其他 ID 明确拒绝。
显示名统一为 `SuperIsland`，记录 `WE1BuildType=Optimized`；`WE1SourceRevision` 与
`WE1SourceExecutableSHA256` 直接取自已核验构建回执，以供现有安装验收流程读回。
WE1Debug 身份沿用原本地打包政策，剥除 `CFBundleURLTypes`，避免占用生产 OAuth / deep links；
正式身份保留其原有 URL 回调。以上变更只用于输出副本，不修改源 App 的 Info.plist。
主程序、Helper、EventTool 必须包含所选的唯一架构；每个实际包含的 Mach-O、framework 和
Node（若有）都必须支持该架构。缺失 Helper/EventTool、错误 daemon plist、测试/调试运行时、
覆盖率、指向包外的符号链接或其他架构缺口均拒绝；没有 Universal 输出选项。
native 加载路径若依赖其他 App、用户目录或 Homebrew 等构建机绝对路径，也会拒绝；
macOS 系统库及可重定位的包内加载路径保留。

Node 不属于原生保持唤醒依赖，本工具不会补装它。无 Node 时仍可制作原生测试包；清单记录
`bundled_node=false`。无论是否附带 Node，均记录 `extension_runtime_portability_verified=false`，
不能据此宣称 JS 扩展跨机验收。源 App 若需要附带其他运行时，必须在生成回执前准备完整，
不能在摘要绑定后替换文件。

签名顺序固定为：先 deep 签嵌套代码并保留其原 entitlements，分别恢复 Helper/EventTool 的
固定 identifier，最后不带 deep 封装外层。deep 阶段不把主 App 权限应用到所有嵌套代码。
外层保留源 App 已有权限；未签名主 App 使用当前已提交源码声明的
`SuperIsland/SuperIsland.entitlements`。签名后逐组件比对权限，不增加权限键。
三个核心组件必须具有相同的真实证书身份及 Hardened Runtime，并通过严格签名检查。
只从输出包提取嵌入的公开证书用于核验，不从 Keychain 导出任何密钥。

成功输出包含：

- `SuperIsland.app`
- `SuperIsland-<构建号>-<arm64或x86_64>-test.zip`
- `manifest.json`、`SHA256SUMS.txt`、`说明.txt`

ZIP 解包后再次校验完整 App 摘要、所有实际 native 架构、固定 identifier 和证书身份。
仅完成这些检查才写成功 manifest。失败不覆盖旧输出、不生成成功记录，保留本次新目录供排查。
清单固定包含 `scope=native-keep-awake-test`、`test_only=true`、`notarized=false`、
`installed=false`、`runtime_validation=not_performed`、`gatekeeper_bypass=false`。
源码身份、完整 App/主程序/ZIP 摘要、架构清单及核心证书指纹也会记录。

其他 Mac 仍可能被 Gatekeeper 拒绝。用户必须按系统正常流程批准合盖 daemon，并在 Codex
审核信任新增 hooks；程序不能代替这些授权。签名通过、安装成功、真实任务自动释放和物理合盖
连续性分别验收。本工具不会请求发布账号、公证凭据或自动执行这些设备操作。

纯验证测试（注入命令结果，不执行 codesign、Xcode 或真实打包）：

```sh
python3 -B -m unittest discover -s scripts/tests -p 'test_package_keep_awake_test.py'
```
