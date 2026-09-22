# 构建与发行

## 当前维护版

本分支最近安装的构建是 **20260922004644**，对外名称为 **SuperIsland**。
它使用本机签名，Bundle ID 保留为 `com.workview.SuperIsland.WE1Debug`，以沿用已有设置和权限身份。
本仓库尚未发布该构建的 GitHub Release；本机 ZIP/DMG、源码推送与公开发行是不同步骤。

已验证的平台是 Apple Silicon Mac，部署目标 macOS 14。最近构建工具为 Xcode 27.0。
当前没有这批新增功能的 Intel 安装验证，不将下方保留的上游 Intel 脚本当成已验证产物。

## 从当前分支编译

需要事先具备 Xcode、XcodeGen、Python 3、Node.js 20+、npm 和 esbuild 0.27.7。
准备 provider 会按仓库的 package-lock 下载依赖，并禁用依赖生命周期脚本；不会登录 WhatsApp。
生成后的目录必须是新目录，脚本会保留已有输出。

```sh
xcodegen generate
python3 scripts/prepare-we1-whatsapp-provider.py \
  --esbuild /path/to/esbuild \
  --output-dir build/LocalRelease.noindex/Provider

xcodebuild -project SuperIsland.xcodeproj -scheme SuperIsland \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/LocalRelease.noindex/DerivedData \
  PRODUCT_BUNDLE_IDENTIFIER=com.workview.SuperIsland.WE1Debug \
  WE1_WHATSAPP_PROVIDER_DIR="$PWD/build/LocalRelease.noindex/Provider" \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES \
  ENABLE_DEBUG_DYLIB=NO ENABLE_TESTABILITY=NO \
  ENABLE_CODE_COVERAGE=NO CLANG_ENABLE_CODE_COVERAGE=NO \
  CLANG_COVERAGE_MAPPING=NO CLANG_COVERAGE_MAPPING_LINKER_ARGS=NO \
  GCC_GENERATE_TEST_COVERAGE_FILES=NO GCC_INSTRUMENT_PROGRAM_FLOW_ARCS=NO \
  SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule \
  build
```

把 `/path/to/esbuild` 换成已安装的指定版本路径。首次解析 Swift 包需要网络。
上述步骤只产生构建输出，不安装或重启现有应用。

## 打包与安装边界

1. 提交已审查的源码，在构建前后核对 Git revision、tree 和工作区状态。
2. 保存真实构建退出码、源码身份、主程序及完整 `.app` 的哈希回执。
3. 使用 [本地 Release 打包器](local-release-packaging.md) 在新目录生成 `SuperIsland.app` 与 ZIP；该文档说明完整回执字段、参考 app 和签名用法。
4. 检查签名、实际架构、测试运行时排除、ZIP 解包内容，保留 manifest 与校验和。
5. 需要 DMG 时，从同一个已签名 app 制作映像，再校验映像、只读挂载并核对内部 app。DMG 不会自动获得 Apple 公证。
6. 安装前先退出旧版，完整保留回滚副本；新版本只安装一份。安装后核对实际路径、构建号、单实例、权限和登录启动状态。

现有用户使用相同本机签名身份升级时，可比较指定签名要求。其他机器不能把本仓库中的证书名称当成已拥有的签名证书；自行构建需要自己的签名配置和对应系统授权。

本次签名包不包含开发用 debug dylib、测试 bundle 或覆盖率运行时。名称变化没有迁移偏好、扩展或日志目录，也没有接管上游 `superisland://` 回调。

## GitHub 同步与公开发行

- `git push` 保存源码、文档和所选检查点，不等于创建可下载安装的 Release。
- 当前维护版的自动更新仍沿用独立的 `we1-构建号` tag 及 `SuperIsland-WE1-构建号-架构.dmg` 匹配协议，并核对下载应用身份和签名。内部兼容标记不影响应用对外名称。
- 如果今后改为对外统一命名的在线更新包，需要一并安排旧客户端兼容，不能只更换远端文件名。
- 对外发行前应另行验证 Developer ID 签名、公证、安装与升级，以及各目标架构；不要直接运行含上传行为的脚本作为本地打包步骤。
- 历史 `superisland-*-installed` 和 `we1-*-accepted-*` 检查点用于追溯，不能单凭 tag 名宣称所有功能已验收。

## 保留的上游工具

以下脚本保留在仓库中，供上游原始构建流程参考；它们没有替代本分支的安装和签名步骤。
运行前应阅读脚本，确认输出目录、应用身份、依赖下载和远端操作，避免清空正在使用的 `build/` 或覆盖已有 app。

| 用途 | 脚本 |
| --- | --- |
| 上游 Apple Silicon 本地 DMG | `scripts/build-dmg.sh` |
| 上游 Intel 本地 DMG | `scripts/build-dmg-intel.sh` |
| 上游签名、公证、发行流程 | `scripts/build-and-release.sh`、`scripts/build-and-release-intel.sh` |
| 带 debug dylib 的本地调试包 | `scripts/package-we1-debug.sh` |
| 本分支的本机优化 Release 包 | `scripts/package-local-release.py` |

上游 Homebrew 模板和站点归各自维护者所有；本次同步没有发布 Homebrew 包，也没有更新上游仓库。
