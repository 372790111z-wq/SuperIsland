# KA1 保持唤醒：实施与验证记录

> 2026-10-23 当前进度：经用户批准的临时 admin 域 Code Signing 信任和后台许可重载，现装 20261023002022 的辅助程序已实际启动并完成签名 XPC 回验，随后正常释放/撤销以准备更新。Codex 原通知共存转发与就绪状态修正已通过回归，正在准备新候选；真实 Codex 配置尚未改动，真实任务/物理合盖自动释放仍待验收。临时信任须在本轮实测后恢复。下方保留按阶段的历史证据，早期状态由后续对应日期记录取代。

> 最新决定：用户要求先不接入 Kimi Code。桌面/CLI 两项暂缓，实际测试连接已断开；源码禁止接入、启动恢复及轮询。保留以下历史证据，停止 Kimi 适配和验收；其余来源范围不变。当前标注归档 20261022。

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


## 2026-10-22 本机系统注册与接电无外屏合盖验收

候选20261022174144（源码567e60e）经用户明确授权、完整备份后已在本机macOS27.0.1安装。15项窗口增强偏好保持；Chrome修复没有改动。首次真正调用register后得到SMAppServiceErrorDomain代码1，同时状态成为requiresApproval；用户完成系统批准后，App显示合盖已就绪，系统daemon实际运行。运行进程精确路径为/Applications/SuperIsland.app/Contents/MacOS/KeepAwakeHelper；运行中与磁盘签名、identifier及证书leaf pin均核验一致。因此，本机自签包在本轮已获系统批准并运行，不能再把缺公证当作本机注册阻塞，也不据此宣称其他系统版本或正式分发条件已验收。

在手动保持模式中，App显示合盖保持已开启，pmset读回SleepDisabled=1，并存在主进程的普通防空闲休眠断言。用户断开外接屏、保留AC电源，完成物理合盖/开盖。受控工作探针只记录时间、序号、机盖状态、在线外屏数量和系统休眠开关，不读取IDE正文。

- 原始109条样本中，seq45–107连续63条同时满足机盖关闭、外屏数0、SleepDisabled=1：2026-10-22 18:08:11至18:13:29，持续318.1秒；前一条外屏缓存仍为1、后一条已开盖，均未计入。
- wall/monotonic时钟和序号连续，最大采样间隔6.15秒；没有休眠造成的长间隔。对应pmset原始时间窗口没有Entering Sleep/Wake from事件。不是将分段或累计时长当作连续合盖。
- 人工点击停止并恢复后，App显示已核对并释放合盖租约；SleepDisabled恢复为测试前0，PID44356的普通保持断言消失。总开关关闭，运行模式恢复自动，已授权helper保留就绪。15项窗口增强偏好再次比较未变。
- 证据为build/KA1LidAcceptance/20261022-180419-probe下的samples.jsonl、acceptance.json、final-readback.json、pmset-log-during-probe.txt、assertions-after-stop.txt及query-receipt.json；安装/备份回执位于build/KA1Installation/20261022-174602。原始系统查询文件仅本机保留并限制权限。

通过范围为本次接电、无外屏、受控任务合盖持续运行及人工停止后恢复SuperIsland自己的覆盖。系统仍有其他App的防休眠断言，不能声称Mac已自动休眠。真实IDE任务完成后的30秒自动释放、电池/过热保护、异常退出恢复和Mac mini仍待验证；没有据此将全部来源或整个功能标为完成。


## 2026-10-22 Codex 官方状态接入候选

本轮由用户明确要求继续代码；用户不再配合当晚合盖测试。临时手动保持已经停止，未替换现装 20261022174144、未改真实 Codex 配置、未中断正在运行的任务。CLI 与桌面端分别核验，不能互相代替。

### CLI

- 接入入口使用 Codex 官方配置编辑接口，在私有临时 CODEX_HOME 编辑原配置副本，仅合并 `notify` 与本功能的 hooks，再逐文件校验并替换。保留 TOML 注释、其他值、第三方 hooks 和禁用状态；已有第三方 notify 则拒绝覆盖。没有静默信任 hook，用户仍需在 Codex 审阅。
- 配置更改有私有备份、事务日志与冲突恢复。它不是跨文件同时生效的事务；崩溃后需在下一次接入/断开恢复。回滚不能确认时明确报待恢复。断开先撤销凭据和任务记录，再清配置；失败会持久保存“重试清理”入口，重启后也不恢复接收。
- UserPromptSubmit 以匿名 turn_id 建立任务；等待和静默继续保持。Stop 可能请求续跑，不能作为完成；仅同轮官方 `agent-turn-complete` 通知确认完成，主轮 Interrupt 确认取消。缺失结束事件或 API 失败继续未知，需要核实或人工停止。
- PreCompact/PostCompact 使用独立匿名辅助任务键。压缩不能结束父轮，通知后的压缩也继续保持；内部阶段结束不发“任务完成”提醒。所有新身份字段均由既有 HMAC 覆盖。
- 事件工具核验实际父进程的 OpenAI 签名和 CLI/服务角色。普通 CLI 即使位于桌面 App 内、没有 TTY，也不误认作桌面任务；共享后端、无法可靠归属的调用被拒绝。接入不会重放过去的开始事件，不能接管接入前已运行的 CLI 任务。

### 桌面端与共享服务

- 只连接已经存在的官方本机共享服务，不通过新建服务伪装成连接用户原任务，不启动/恢复/发送任务。每 5 秒只读 loaded threads、线程状态及不加载 items 的轮次元数据；不保存标题、预览、路径、提示词、回复或工具内容。
- 同一服务内 `appServer` 来源不是具体桌面客户端身份证明，文案明确这是本机共享服务通道。读取完整分页、复核线程状态；缺页、断线、未知、消失的线程均不能证明结束。已观察到的全部轮次明确终结且线程 idle 后，才开始 30 秒释放。
- 首次连接可补捕该服务中已运行的任务；重复连接保留原序号与 guard，取消连接后的迟到响应不能复活任务。不能连接当前版本的服务时显示未接通，不把“等待任务”当作成功状态。
- 本机当前默认公开控制 socket 不存在，因此尚未证明现有 Codex 桌面任务的真实接入；云端任务即使使用本地工具，也不等同支持本地 hooks。该通道的真实性仍需可用版本/服务与实际任务验收。

### 验证与交付边界

- `build/KA1CodexIntegrationValidation/native-tests-final.log`：192 项，2 项 Kimi 按暂缓决定跳过，实际 190 项通过，0 失败。包含新增 Codex 契约、配置窄合并与失败恢复、分页/隐私边界、轮次状态机、真实 Service 调度与清理重试，以及既有长任务/helper/Chrome 全屏移屏回归。不是物理合盖自动完成验收。
- 配置编辑测试使用本机已安装 CLI 的官方 TOML 编辑器和隔离临时配置，未使用真实账号或模型。状态读取测试使用公开 schema 的受控元数据响应，未连接用户真实桌面任务。
- `build/KA1CodexRuntimeFixtureFinal.noindex/receipt.json`：真实签名 CLI `0.163.0-alpha.10.2` 在临时 home/工作区执行，连接仅回环固定响应服务；1 次 Responses 请求，0 次其他请求，退出码 0。当前事件工具 SHA256 `eec5a685994a1e7a2e3740388cbd66f7ee70b6d35b1514c7ee53a112e0662209` 收到 1 条匿名完成事件，父进程来源、turn 身份及 HMAC 均通过。外层系统沙箱禁止非回环网络；没有安装 hook 或绕过其信任。临时凭据与配置已清理。
- 正向实证仅覆盖真实 CLI 完成通知链路。用户实际环境的开始、等待、压缩及完成后的系统自动释放仍待验收；普通 CLI 与共享后端、桌面本地与云端须分别验证。原 27 条目、Kimi 暂缓和其他来源边界不变，PRD v0.4 与标注全文未改，整个 KA1 仍是实施中。

契约依据：[Codex hooks](https://learn.chatgpt.com/docs/hooks)、[完成通知](https://learn.chatgpt.com/docs/notifications)、[App Server](https://learn.chatgpt.com/docs/app-server)及本机 CLI 导出的公开 schema。实际支持以运行时能力和有效事件为准，不锁私有 UI 或内部数据库。


## 2026-10-22 桌面本地接入与跨 Mac 测试包

用户要求继续完成 Codex 接入并可供其他 Mac 安装使用；暂没有 Developer ID，已明确选择先完成通用代码和测试包。本轮仍遵循已确认 F05/F06 的主动接入、信任和系统授权规则，不把“安装后可用”解释为静默改配置或绕过批准。

### 实现

- 按官方签名、bundle ID、已运行 App 和 LaunchServices 查找 Codex，支持 App 改名、其他安装目录、用户 Applications、GUI PATH 未包含 Homebrew 的情况。只从已验证桌面子进程提取 HOME/CODEX_HOME；不保存 PID、提示词、令牌或其他环境值。多个实际 home 冲突时明确拒绝任选。
- CLI 和桌面 Local/Worktree 使用同一份官方 hooks/notify 配置和私有 v2 路由收据；事件工具根据真实签名父进程角色只选择一个来源凭据。支持 v1 CLI 窄迁移，断开一项保留另一项，最后一项才清理自有 hook/恢复 notify；Interrupt 超时修正为 3 秒。保留原禁用状态、第三方配置、备份和失败恢复，不静默信任。
- 接入确认冻结环境与通道；不能在只读确认后因 socket 消失转为写配置。新桌面接入默认 hooks；旧 RPC 通道按保存 profile 读取同一服务的全部 loaded 任务，不凭历史 source 字段伪造桌面归属。同一真实 home 的 RPC 与来源 hooks 互斥，防止 CLI 任务重复计数/提醒，包含符号链接别名判断。
- 保存实际配置 home、CLI 和 socket 归属。重启只重建自有凭据，不自动重写 Codex；接入事务中途崩溃留下的孤立意图变为可重试清理。卸载先释放该来源保持再运行外部编辑器；编辑器被移动时只更换已验签工具，不改变待清理 home。
- 新增独立原生测试打包器 `scripts/package-keep-awake-test.py`，不依赖本机 Applications 的参考安装；核验源码回执、架构、加载路径、固定组件身份、同证书和权限，ZIP 解包回验。测试包不需要接收者的 Python/Xcode/Homebrew 来运行原生保持功能，不复制本机私钥，不自动安装或修改系统信任。

### 本轮实证

- `build/KA1CodexPortableValidation/native-tests.log`：230 项，2 项 Kimi 暂缓跳过，实际 228 项通过，0 失败。覆盖环境发现、配置共享/迁移/撤销、配置位置绑定、崩溃意图恢复、确认模式冻结、别名互斥，以及既有长任务/helper/Chrome 回归。
- `build/KA1TestPackagerValidation.noindex/pure-validation.log`：16 项打包政策测试通过，0 失败；检查测试/正式回调隔离、身份、架构与原生依赖，不执行系统授权或安装。
- `build/KA1CodexRouterRuntime.noindex/receipt.json`：实际官方 CLI 0.163.0-alpha.10.2 通过回环固定服务运行，外层禁止非回环网络；两个来源同时登记，CLI 仅收到 1 条匿名完成事件，桌面收件箱 0 条，HMAC 正确，CLI exit 0。没有安装 hooks、没有信任绕过、没有使用真实 home/账号/外网模型。这不是桌面真实任务验收。
- 新隔离原生预览实际显示 27 来源、Codex CLI/桌面两项接入入口、默认总开关关闭；桌面自动环境发现成功，确认说明为本地 hooks、信任及 Cloud 边界；点击取消，未写真实配置，预览正常退出。记录 `build/KA1CodexPortableValidation/ui-readback.json`。原安装版和 Chrome 未被替换/干扰。
- PRD v0.4、当前 20261022 annotation 全文及历史 HTML 均不变；本轮为实现修正，整个 KA1 维持实施中。

### 不得越过的验收边界

目前只能准备原生保持唤醒的 arm64 测试包；未公证，接收机仍需 macOS 正常批准。x86_64 入口会严格检查对应实际产物，未产出/未实测 Intel 或 Universal。未捆绑 Node，不据此宣称所有 JS 扩展跨机可用。用户已明确先做这类测试包，不能把它当正式公开发行版本。

桌面 Local/Worktree 必须实际审阅信任并在本机新任务验证开始、等待、完成和30秒释放；接入前旧任务不能补放开始，Cloud/Work Cloud 不运行本地 command hooks 的场景仍未覆盖。CLI 连接没有可可靠客户端归属的 headless/shared daemon 时也会拒绝事件；不得将直连 CLI 的完成夹具提升为所有 CLI 支持。缺失或未知结束信号继续保持，不伪造完成。

本轮原生工具明确拒绝控制 `com.openai.codex`；未换后端绕过。REA 静态检查因 app.asar 声明/实际 unpacked member hash 不一致停止，未绕过完整性检查，不能据此推断本版桌面内部行为。真实 Codex 的 hook 信任操作需要用户在产品中完成；新候选安装需按具体产物授权，另机与合盖自动完成仍分别验收。

依据：[官方 hooks](https://learn.chatgpt.com/docs/hooks)、[本地执行模式](https://learn.chatgpt.com/docs/modes)、[公开 App Server](https://learn.chatgpt.com/docs/app-server)。公开传输不能替代当前桌面没有开放的内部连接；本地 hooks 路线与既有 RPC 能力分别描述。

打包实测补充：首次新打包器在提取嵌入的公开证书时，codesign 将分开的可选 prefix 当作第二个目标而拒绝。已用当前 codesign 实测附着 `--extract-certificates=<prefix>` 成功，修正调用并增加单目标参数回归；16 项纯打包测试通过。失败输出保留，后续从新的干净源码回执重新构建打包，不将失败目录当成功包。

## 2026-10-23 实际接入阻塞与辅助程序状态修正

用户已明确授权 Codex 接入、辅助程序更新注册及真实合盖验收。本轮先保存私有配置快照到 `build/KA1CodexAcceptance/20261023-090732`，没有读取任务正文或账号数据。

- 旧 helper 经 SuperIsland 正常释放、撤销，PID 45609 消失且 `SleepDisabled=0`；随后注册记录指向构建 20261023002022，但 amfid 报 `AppleMobileFileIntegrityError -423` 未知证书链，launchd 报代码签名启动约束不匹配。未出现新版 helper 运行进程，不能以 UI 注册成功称其已运行。
- 此本机自签证书仅在当前用户 Code Signing 策略受信任，admin/System 域没有对应信任；没有可用 Apple Development/Developer ID 身份。已导出并核对同一公开证书及原 admin 信任设置快照，没有导出私钥，没有修改信任。临时 admin 仅代码签名信任是待用户确认的本机实验，不能保证 AMFI 接受，也不是跨机分发方案。
- Codex 原 notify 程序是 OpenAI 签名的 `SkyComputerUseClient`。SuperIsland 接入被原有冲突保护拦截；config.toml/hooks.json 与操作前 SHA256 一致，未删除或覆盖该通知。保留原通知并增加转发的方案已另行请求用户确认，尚未实现或写配置。

本轮实现修正保持现有授权界面/PRD/标注不变：`authorize()` 必须收到有签名约束的 XPC `status` 成功回复，且当时授权与意图仍有效，才启用并显示就绪；仅有 SMAppService 注册状态不够。状态请求与续租/释放分离，关闭、撤销或退出后的迟到回复不能重新启用。没有自身待恢复租约时，恢复检查只读 status，不虚构已恢复自身电源改动。撤销仍须本 owner 的释放明确成功后才正常 unregister；未采用“无自身租约/单次 SleepDisabled=0 就直接注销”的不安全旁路。启动失败的服务清理仍需合法启动后按正常流程处理，不声称已解决所有跨客户端注销竞争。

验证：隔离授权/恢复/身份测试 42 项通过；实际 Xcode 回归 `build/KA1CodexAcceptance/20261023-090732/ReadinessXcode.noindex/xcodebuild.log` 共 249 项、2 Kimi 跳过、247 通过、0 失败，源码四文件在运行前后哈希一致。测试不更改真实授权或电源。原生只读采样器和停止/证据说明已准备在同一私有目录，合成自测未发起主机查询，尚未启动真实采样。

当前总开关仍关闭、`SleepDisabled=0`，没有开始 Codex 真实任务或物理合盖测试。系统临时信任和原 notify 共存方案的确认仍待用户回复；不能将代码回归或采样准备报告为接入、合盖运行或自动释放成功。现装仍是 20261023002022，尚未包含本节状态修正。

## 2026-10-23 原通知共存与实际辅助程序启动

用户已分别批准临时系统代码签名信任（测试后恢复）和保留原通知增加转发。公开证书 SHA256 `41ffdda8cdeeb2271d395b34b3ee63d09aa283448ad4bbccab81ed7a075af466` 的 admin 信任仅含 Code Signing 策略；未改 SSL、SystemRoots 或原 login 信任/私钥。后台许可正常关闭再恢复后，launchd 实际运行 helper PID 91082，动态签名身份和磁盘 helper 一致，App 的签名 XPC 检查/释放成功。随后为更新正常撤销，服务消失，`SleepDisabled=0`。此证据只证明本机辅助程序启动与通信，尚未证明新包、真实任务或合盖自动释放。

- 安装器新增显式 `allowNotifyForwarding`，默认仍拒绝已有第三方通知；生产入口只在现有接入确认说明保留原程序、参数和通知后启用。官方配置编辑器只在隔离副本编辑，再按原事务核验落盘。
- 通知命令为固定原生工具前缀加原 notify argv。观察器只提取匿名生命周期；无来源、凭据失效、收据损坏或观察失败仍 `execvp` 原程序，复用原始 C argv，保留 PID/PPID、环境、工作目录、标准输入输出和原退出码。无 shell 拼接，不记录通知正文或原始 JSON。
- 两个来源共用同一转发命令，不嵌套；最后一个来源断开且配置未改时恢复原入口。若用户修改了仍依赖本转发器的原参数，保留配置、收据与 hooks 并提示待清理，避免留下已失效依赖；独立替换的用户通知不被覆盖。
- 运行时拒绝自调用、符号/硬链接和 PATH 自递归；非法委托或原程序无法启动返回 127，不输出输入内容。没有修改 hook 信任文件，也不把 Stop 当完成。

验证：`build/KA1CodexNotifyForwardValidation/FullXcode-r2.noindex/xcodebuild.log` 共 263 项，2 项 Kimi 暂缓跳过，261 项通过，0 失败；运行前后七个源码/测试文件哈希相同。首次测试仅因 `/var` 与 `/private/var` 别名断言失败，已改为核对目录设备号与 inode 后重跑；原始失败日志保留。另有 28 项隔离安装/撤销测试、14 项纯契约测试及 27 项原生进程检查通过，包括观察器异常仍转发、原始字节/参数/stdio/退出码保留。未调用真实原通知程序或运行真实 Codex 任务。

本轮仍为已确认 PRD v0.4 的实现修正；页面流程、annotation ID 和来源范围不变。当前原 config.toml/hooks.json 与接入前快照相同，接下来需从干净提交构建并安装、实际连接与审阅信任，再做真实 Local/Worktree 生命周期和物理合盖验收。临时信任的窄撤销、原设置回验与其他 Mac 实测分别保留为未完成项。
