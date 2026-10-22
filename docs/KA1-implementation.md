# KA1 保持唤醒：实施与验证记录

> 2026-10-22 当前进度：已按用户直接开始代码授权修正长任务策略；下方早期“等待30秒/信号3分钟释放”记录已由本文件末节和PRD v0.4取代。合盖系统授权与设备验收仍未执行。

> 最新决定：用户要求先不接入 Kimi Code。桌面/CLI 两项暂缓，实际测试连接已断开；源码禁止接入、启动恢复及轮询。保留以下历史证据，停止 Kimi 适配和验收；其余来源范围不变。当前标注归档 20261021-3。

日期：2026-10-21。分支：`feat/keep-awake`。基线：`c5cccc703dff1793bc7ee4dcc65711de59e0c098`。

**状态：实现中，未完成整个 KA1，不能按「全部任务来源已支持」交付。** 用户已确认 HTML、PRD 并授权代码实施；没有缩减原 PRD 的 17 个来源范围。本记录描述实现进度，不替代 [KA1 PRD](product-package/06-SuperIsland保持唤醒PRD-KA1.md)。

## 已落地代码

- 原生菜单子菜单和独立设置页：自动/手动、30/60/120 分钟与不限时、暂停、停止、屏幕策略、保护、来源搜索、通知权限入口与恢复记录。
- 纯状态机：多来源/多会话聚合、顺序与重放处理、等待释放 30 秒、未知状态与最多 180 秒失联宽限；手动期限不被暂停延长；电量边界、断电、低电量模式与热保护锁定。
- IOKit 普通保持与显示保持按本功能断言 ID 创建和释放；屏幕熄灭通过固定系统命令执行一次，不循环黑屏。MacBook 有外屏时不执行会影响全部屏幕的操作。
- 独立设备判断：内置电池和机盖能力；桌面设备不虚构电池百分比，不显示合盖/电池管理入口。
- 事件通道：本用户私有目录、每来源随机密钥与连接代次、HMAC、时间窗、序号、大小/数量限制；匿名会话；无网络监听端口。原始 hook 输入不落盘、不转发。正常退出移除凭据；崩溃时队列有数量上限。
- 配置接入：用户点击并确认后才修改；JSON 窄合并、原文件备份、原有 hook 保留、重复接入幂等；插件只写专属文件，已有文件内容不同则拒绝覆盖；断开使凭据失效。
- 合盖候选：自有 SMAppService daemon、双向代码签名约束、有限 XPC 操作、最长 180 秒租约/30 秒续期、持久化写入意图、恢复回读、helper 重启先恢复、原有电源覆盖不接管、独立电源和热保护。正常退出请求释放，异常时依赖 daemon 租约与 launchd 重启恢复。**尚未安装、系统授权或实机合盖验收。**
- 构建新增两个独立工具目标，App 包内各放一份；本地 Release 打包器显式签署 helper 标识。没有改动现有安装包。

## 来源覆盖：原 17 项保留，新增 10 个形态核验条目

用户已明确加入 Kimi Code、Qoder、TRAE SOLO、ZCode、WorkBuddy，并要求 CLI 与桌面分别核验。当前共 27 个条目，不等同于 27 个已支持来源。原四个 hook 候选保持；Kimi Code 桌面端只读候选已经按用户决定暂停，其他来源仍按独立状态推进。安装入口可用、协议测试通过与真实任务验收分别记录。

| 来源 | 当前代码 | 尚未完成 |
| --- | --- | --- |
| Claude Code | Hook 合并、事件白名单、等待事件、匿名事件工具 | 本机实际任务全流程；长时间没有 hook 的任务健康信号；不能将三分钟后释放算持续运行验收 |
| Gemini CLI | Hook 合并、毫秒超时、JSON no-op、权限等待事件 | 目标版本与长任务实测；CLI 不在本次 PATH 清单中 |
| OpenCode | 独立插件、状态/权限事件、20 秒心跳 | 当前运行时的事件顺序、断线及等待覆盖；未在真实来源进程加载 |
| Pi | 独立扩展、session 生命周期、agent_settled 与心跳 | 当前版本与自定义交互等待覆盖；未在真实来源进程加载 |
| Claude Cowork | 清单与未接通反馈 | 可靠接口及适配器 |
| Codex CLI | 本机运行时/schema 已核验，元数据解析候选已实现；接入入口仍关闭 | 真实 hook 信任与事件、静默长任务健康、来源身份 |
| Codex 桌面端 | 本机应用已确认；与 CLI 共用的元数据解析候选 | 可靠客户端区分、桌面本地任务与远端编排边界、健康信号 |
| Copilot CLI | 清单与未接通反馈 | 当前 hook 配置与状态适配 |
| Hermes CLI | 清单与未接通反馈 | 每轮结束与等待信号；参考脚本存在 CPU quiet 降级，不能照搬 |
| Hermes Gateway | 清单与未接通反馈 | Gateway 生命周期与本地依赖适配 |
| Cursor | 清单与未接通反馈 | 当前 IDE hook、等待及任务身份 |
| Cursor Agent | 清单与未接通反馈 | 独立来源映射及与 Cursor 去重 |
| Cline | 清单与未接通反馈 | 可靠任务接口，不能只看扩展常驻 |
| Aider | 清单与未接通反馈 | 交互等待与工作的可靠区分 |
| Conductor | 清单与未接通反馈 | 多任务接口与适配器 |
| Goose | 清单与未接通反馈 | 生命周期接口与适配器 |
| Windsurf | 清单与未接通反馈 | 当前产品版本接口与适配器 |

此前环境检查遗漏了 Codex，用户指出后已更正：本机 `/Applications/ChatGPT.app` 为 26.1013.40934，其内置且位于 PATH 的 Codex CLI 为 `0.163.0-alpha.10.2`，`codex features list` 返回 `hooks stable true`。不能再将 Codex 列为缺少本机环境。Mac mini 可用性仍未知。没有自行安装软件或改写真实 agent 配置。

### 本机五款扩展

本轮环境、接口及真实交互证据见 [本机来源核验记录](KA1-local-source-verification.md)。Kimi Code 桌面端采用精简字段的本机 HTTP 状态查询，每 5 秒刷新；不以进程存在判定任务运行。CLI 单独保留未接通项。其他四款已确认安装与部分内置运行时，但可靠来源身份、等待和持续健康信号尚未闭环，不开放接入。

新增 7 项本机来源测试，连同引擎、事件工具和接入测试共 34 项通过；异步轮询修正后另重跑 7 项全部通过。原生预览已确认 27 条目、Kimi 桌面端只读确认与空闲响应，用户已发起真实任务，但本机 Kimi 更新为 1.1.1，实测未触发。已修复端口检查卡住和旧状态不失效问题，10 项针对性测试通过；新预览正确标记当前版本尚未核验，1.1.1 适配仍未完成。预览与生产 App 的设置隔离，未替换安装版。

### Codex 本机核验与解析边界（2026-10-21）

- 已由安装的 CLI 直接导出 app-server schema，保存于 `build/KA1CodexSchema`。`HooksListResponse` 的事件枚举包括 12 个事件和独立 hook 信任状态。这证明当前运行时提供接口，不证明某条真实任务已触发 hook。
- 事件工具新增 `codex-cli` / `codex-desktop` 元数据解析候选及 `{}` no-op 输出。只接收明确事件，不读取 transcript 文件、提示词或回复内容；SessionStart 不算工作，子任务开始/结束不覆盖父会话，Stop/Interrupt/SessionEnd 仅进入 idle，避免虚假完成通知。真实等待覆盖仍需验证。
- CLI/桌面共享配置及本地后端时，不能靠两个同样的 hooks 注册把同一任务重复记到两处；目前公开输入字段未证明可靠的客户端身份，尚无静默健康信号。因此不启用安装入口，不把解析夹具提升为端到端支持。四个安装候选、十三个未完成接入的总数不变。
- 本机 ASAR 的 REA 静态分析遇到 unpacked `permissions.node` 的声明/实际哈希不一致而停止；未使用该分析图作行为依据，也未修改应用。后续依据是本机 CLI 导出 schema 与官方 hook 契约。
- 本次编译及 `KeepAwakeEventToolTests` 4 项通过，0 失败；新增 Codex 测试在两个来源上各验证 14 组事件、输出 no-op、HMAC 接收及正文不外传。日志：`build/KA1Validation/codex-event-tests.log`。这是隔离夹具，尚未在真实 Codex 任务注册/触发。
- [Codex hooks 官方文档](https://developers.openai.com/codex/hooks)说明非受管 hook 需审阅信任；Stop 可被其他 hook 续跑，子任务 hook 使用父 session ID。云端编排即使工具在本地执行，也不等同于本地 command hook 支持。未绕过信任或将这些情况标为已接通。

## 验证证据

- XcodeGen 生成项目；独立 `build/KA1Final` 干净构建通过。使用 `/Applications/Xcode.app/Contents/Developer`，没有修改系统 `xcode-select`。
- 原生 XCTest：57 项通过，0 失败；其中 36 项 KA1 测试，21 项既有系统反馈/通知解析测试。最后菜单实时状态刷新修改另经编译通过。最终结果见 `build/KA1Validation/xcode-test.log`。测试覆盖状态机、IPC 鉴权、真实事件工具、配置保留、租约故障与真实普通 IOKit 断言；并包含既有系统音量/亮度与 Mac 通知解析测试。
- Node 插件夹具：OpenCode 与 Pi 两项生命周期、心跳、HMAC、无正文输出检查通过。使用临时目录与自己构建的事件工具，没有加载到真实第三方软件。
- 插件夹具首次重跑发生固定延时等待不足，已改为等待实际事件结果并重跑通过；不把固定 sleep 后无结果认作来源本身不支持。
- 原生隔离预览 `com.workview.SuperIsland.KA1Preview`：只启动 KA1 设置和菜单，不启动岛、扩展、窗口增强、生产统计或更新；真实点击验证手动开始、暂停、停止、来源搜索和保护分区。
- 暂停后 `pmset -g assertions` 未发现 SuperIsland 本次保持断言；`pmset -g` 的 `SleepDisabled` 始终读为 0。系统没有注册 `com.workview.SuperIsland.KeepAwakeHelper` 服务。
- 原生 AX 发现父级标识传播覆盖子控件，修复为独立容器后，设置、状态卡、开关、模式、屏幕策略、来源清单和来源行、保护、通知及 helper 管理、停止按钮、恢复记录标识均已实际读取。菜单展开、计时长时间到期、真实通知横幅与实际撤销尚未完成原生验收。
- 已确认 HTML 原样保留，SHA-256：`595dfc972b169f389c3712d9efdf402a20896110d855c843b81642013acf7274`。不拿原型模拟当作 Mac mini 或合盖行为证据。

构建出现 CoreSimulator 版本警告和测试宿主的系统 linkd 提示；macOS 编译及所列测试仍成功。这些日志不代表已通过 iOS 或系统服务验收。

## 尚未完成的交付条件

1. 原 13 个未接通来源及新增 9 个形态的接口核验和实际适配代码；原 4 个 hook 候选与 Kimi 桌面只读候选也需真实任务验收。Kimi 同会话等待与后台任务并行时的状态优先级仍需补足，不能按全场景已支持交付。
2. 证书签名安装包的 helper 注册/授权、XPC 身份拒绝测试、主 App/helper 强制终止与系统重启的真实恢复回读。当前只有编译、协议和模拟故障测试；不得据此称合盖已可用。
3. MacBook 接电/电池、内屏/外屏与真实合盖任务连续性；Mac mini 实机；真实屏幕常亮/熄屏行为与通知权限/横幅。需要用户配合设备与权限操作。
4. 与其他电源工具并存的实机冲突测试：全局开关的三值比对不能识别其他工具写入相同值后又改回的历史（ABA）。当前实现避免接管已有覆盖、检测可见冲突；更强的所有权保证仍需验证。恢复失败保持记录，不声称成功。
5. 正式签名包、旧 App 备份与替换、完整功能回归、提交、推送和合并均未执行。

## 标注归档

当前归档为 `20261021-2`，保留 `20261021` 及更早历史版本。KA1 的 `fullPrdContent` 与用户明确授权扩展后的 PRD v0.2 文件一致；要求标记 `implementationStatus: in-progress`。已确认的 HTML v0.1 原样保留，不声称新增 HTML 已获确认。这是原生 SwiftUI 功能，CSS 形式 selector 沿用现有项目格式，实际原生查找使用 `nativeAccessibilityIdentifier`；没有宣称浏览器 DOM 中存在这些控件。

## 当前实现依据

- [Claude Code hook 官方契约](https://code.claude.com/docs/en/hooks)：使用明确事件和元数据，不沿用参考脚本的正文转发。
- [Gemini hook 配置](https://geminicli.com/docs/hooks/)及[事件契约](https://geminicli.com/docs/hooks/reference/)：超时为毫秒；只输出 no-op JSON。
- [OpenCode 插件事件](https://opencode.ai/docs/plugins/)：来源插件候选，真实运行时仍需确认事件覆盖。
- [Pi 扩展生命周期](https://raw.githubusercontent.com/badlogic/pi-mono/main/packages/coding-agent/docs/extensions.md)：`agent_end` 不等同于最终空闲，候选使用 `agent_settled`；版本兼容待验证。
- 本机 macOS SDK `NSXPCConnection.h` 的签名约束 API、IOKit 断言 API 与 `pmset -g` 只读结果；此前 HoldMyLid 静态 REA 证据见原型 QA。静态/单元测试不替代权限与设备验收。

## 本机稳定 hooks 适配进展

Qoder CN、WorkBuddy、ZCode 均已收到真实桌面任务的官方 hook 事件；具体顺序和限制见 [本机来源核验](KA1-local-source-verification.md)。公共契约解析及 Qoder/WorkBuddy 窄合并候选已实现，按字段能力兼容，不锁精确版本。当前仍缺静默长任务健康信号及部分授权恢复/提问结束证据，因此这三项尚不开放自动接入，不能称为已端到端支持。TRAE SOLO 尚未确认对应版本的完整接口；不使用私有前端状态或常驻进程替代。

本轮保留已确认 PRD、HTML 和 20261021-3 标注归档，仅记录实现与核验证据；未改变默认策略或通过标注将候选状态宣称完成。

## 2026-10-22 长任务策略修正与候选准备

用户明确要求代码实现：真实开始的任务在等待确认、空闲候选或连接未知时继续保持，不用静默时长推断结束；仅所有任务收到可信完成/取消/失败后延迟30秒释放。保护、显式断开和人工停止仍优先。主程序/辅助程序故障的180秒租约与任务持续时长分开。

实现包括：

- Engine保存已开始意图，连接健康只改变解释；终结后普通等待/续报不复活，只有明确新任务开始可重开。事件新增匿名taskID和startsTask并签入HMAC；旧封包nil/nil签名字节保留，新增metadata删改/null拒绝。
- WorkBuddy公开generation_id和owned Pi任务批次UUID哈希隔离轮次；Pi自动重试复用同批次，agent_settled后才可信完成。其他来源缺轮次的失败/取消候选继续未知，不使用“30秒没新事件”伪造完成。
- 满1024条且无法记录新运行会话时，锁来源级未知继续保持并显式提示；显式断开/重接或人工停止处理，不静默允许休眠。
- Qoder/WorkBuddy/ZCode桌面端增加可主动接入的候选入口。ZCode独立hooks.events/process/args/timeoutMs安装器，保留原关闭状态、其他配置与可恢复备份；没有改本机真实IDE配置。CLI仍单独核验，Kimi继续暂缓。
- Helper错误拥有者不污染合法租约；XPC迟到错误绑定原请求，连接中断即时清除旧状态；显式安全恢复先核对旧租约、意愿与新鲜授权，再续租，不自行注册。主程序退出包含待恢复租约。
- 原生UI使用具体合盖状态；原型v0.2电源模拟及PRD v0.4、标注20261022已同步。Chrome源码和测试从已验收72c6b3a精确纳入7个文件，AppDelegate保留两个功能的独立诊断/预览路径。

验证：

- native-tests-accepted.log：130项测试，2项Kimi延后测试跳过，0失败；实际128项通过。system-feedback-regression.log另通过系统音量/亮度与通知相关回归。包含引擎、真实事件工具、元数据鉴权、配置窄合并、并发/长时/容量、helper恢复与Chrome全屏回归。早期失败为旧策略断言/测试预期，已保留原日志并更正重跑。
- Node适配器夹具（adapter-tests-final.log）：OpenCode和Pi生命周期、重试轮次、心跳、HMAC、无正文输出通过；首次夹具等待运行事件超时后直接核验真实工具可生成事件，使用当前构建工具重跑通过。不是来源真实运行验收。
- 新原生隔离预览com.workview.SuperIsland.KA1LongTaskPreview：首次总开关关闭且“合盖支持未设置”；启用自动但无任务显示等待；停止恢复关闭。来源页27条、Kimi暂缓、三个桌面候选与CLI待验证均实际读回。预览随后正常退出。未开启helper授权、未修改第三方配置。
- 历史标注、v0.1原型字节保持；20261022全文与PRD逐字相同，其他4项需求对象未改。

待验收：真实系统注册/授权与XPC、合盖任务连续性、保护/异常恢复、来源最终完成及自动释放、Mac mini；编译/协议和原型均不替代这些验收。不宣称27项已接通或合盖已可用。后续正式候选本机安装需具体授权，Chrome已验收安装版继续保留。

打包校验补充：初次Release因继承测试覆盖率被packager拦截，已显式关闭覆盖率与调试动态库重建。随后真实包读回发现外层codesign --deep重写了helper的自定义标识；已改为先签嵌套代码、重签helper/事件工具固定标识、最后只重封外层App，并将这两项标识验证加入打包与ZIP解压回读。验证不通过的早期包保留在忽略的build目录，不用于安装。


## 2026-10-22 合盖授权入口修正

本机候选20261022170144经明确授权后点击“继续系统授权”，设置页显示“系统尚未启用辅助程序”，未进入登录项授权；系统服务没有运行，SleepDisabled仍为0。系统日志出现该daemon的record not found。源码检查发现authorize仅在notRegistered时调用register，notFound会被跳过；因此此前结果不能视为一次真实register失败，也不能由此断言是签名/公证拒绝。

修正为只在用户显式授权入口，对notRegistered或notFound调用官方register；已有enabled不重复登记，requiresApproval打开登录项并保持关闭。注册返回后共用一次状态读取；错误仅显示NSError域/代码，未解决状态显示状态码，不输出description/userInfo中的私人路径。没有自动注销、修改系统信任或绕过批准。

新增KeepAwakeLidAuthorizationTests覆盖7种授权路径，与既有7项helper恢复回归一起14项通过，0失败；独立日志为build/KA1AuthorizationTests.noindex/test.log。测试使用注入closure，不注册真实服务、不打开系统设置、不改电源。Chrome全屏修复源码没有改动。本修正尚待重新打包安装后验证真正的系统注册结果；物理合盖仍未验收。

本机SDK说明daemon需公证；Apple官方本机开发示例同时使用Apple签发的开发证书。当前候选为本机自签，codesign通过只证明自身完整性及自有XPC身份，不证明平台接受它。应先取得真实register的domain/code，再区分包装、系统批准、开发签名或发布公证问题。
