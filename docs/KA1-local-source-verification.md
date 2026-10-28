# KA1 本机新增来源核验

> 最新决定：用户要求先不接入 Kimi Code。桌面/CLI 两项暂缓，实际测试连接已断开；源码禁止接入、启动恢复及轮询。保留以下历史证据，停止 Kimi 适配和验收；其余来源范围不变。当前标注归档 20261021-3。

日期：2026-10-21；分支：`feat/keep-awake`。本文件记录实施证据，范围和默认行为以 [KA1 PRD](product-package/06-SuperIsland保持唤醒PRD-KA1.md) 为准。

## 安装和形态

| 产品 | 桌面安装证据 | 独立 CLI 核验 | 当前接入 |
| --- | --- | --- | --- |
| Kimi Code | `/Applications/Kimi Code.app`，初查 1.0.1；18:04 复查已为 1.1.1，`com.kimi.code.desktop` | PATH 和已检查的常见用户 bin 路径未找到；官方 CLI hooks 文档存在，未证明本机独立 CLI 版本 | 1.0.1 桌面只读候选；1.1.1 实测未触发，当前不兼容 |
| Qoder | `/Applications/Qoder CN.app`，0.4.7，`com.qodercn.app` | PATH 未找到独立命令；应用内有 CLI 相关实现，不能等同独立安装 | 待验证 |
| TRAE SOLO | `/Applications/TRAE SOLO CN.app`，0.1.49，`cn.trae.solo.app` | 应用内 `out/cli.js`、`agent-tool-host`、`ctx-cli` 不足以证明独立 Agent CLI | 待验证 |
| ZCode | `/Applications/ZCode.app`，3.16.2，`dev.zcode.app` | 内置 profile 声明运行时 0.13.3 和 `app-server --stdio`；独立可执行形态未证实 | 待验证 |
| WorkBuddy | `/Applications/WorkBuddy.app`，5.8.3，`com.tencent.workbuddy.mac` | 包声明 `wb` 入口且内含 codebuddy-lite-wb；PATH 未发现独立 wb/WorkBuddy CLI，不能把内置引擎算另一已接通来源 | 待验证 |

原 17 项的稳定 ID 和顺序保留。五款各有 CLI、桌面两条独立核验记录，共新增 10 项；“待验证”也可能意味着该形态是否提供仍未知。

## Kimi 桌面只读候选

- 只读取唯一运行的 `com.kimi.code.desktop` 1.0.1 进程拥有的 IPv4 回环监听端口。未知版本、多个实例、无响应或契约变化均返回未知，不自动猜测。
- 请求 `/api/v2/sessions`，限定 `fields=id,archived`、`page_size=1`，分别查询 `activity.status=running/approval/question`。只使用数量归并状态，不保存会话 ID、标题、路径、提示词或回复；不请求历史正文。
- 拒绝重定向、代理、Cookie、缓存与认证存储；响应限制 8 KiB；字段投影不符则拒绝。连接不写 Kimi 配置、不打开总开关，断开取消在途结果。
- 每 5 秒重新读取；任一运行会话优先于其他等待会话；只有等待/空闲后按状态机 30 秒释放；未知仍遵循既有失联宽限。空闲快照不能证明成功完成，不产生完成通知。
- 本机第一次读取时，API 由 Kimi 进程监听且返回成功、运行数量 0。原生预览随后显示“本机只读接口已响应 · 空闲”；用户已完成 Kimi 登录。预览自动模式已开启等待测试，尚未获得真实任务运行/等待结果。
- **未完成边界**：安装包中 `mapActivityStatus` 将同会话的 approval/question 排在 busy 之前。若该会话仍有后台/子任务，列表状态可能隐藏其运行事实。目前仅证明跨会话运行优先；同会话混合状态未闭环。旧版 session/status 接口可能恢复会话，尚未作为无副作用只读补充接入。不能把此候选标为全场景持续保持已验收。

实现：`KeepAwakeKimiMonitor.swift`、`KeepAwakeService.swift`；原生预览 bundle ID：`com.workview.SuperIsland.KA1Preview`。生产安装版未替换，未注册合盖 helper。

## 其他来源的具体缺口

- Qoder：官方 IDE/CLI hooks 文档及本机事件名称已找到。共享配置如何区分桌面和独立 CLI、长时间无工具事件时的健康状态，尚未核验。不能给同一事件注册两份后算两个来源。
- ZCode：安装包含 hooks 配置模式和独立信任校验，事件包括 UserPromptSubmit、PreToolUse、PermissionRequest、Stop 等；本机真实载入及状态契约尚未验证，未绕过信任机制。
- WorkBuddy：安装包含与 Claude 风格相近的 hook 输入及多种 ACP/daemon 路径。桌面与 CLI 配置目录可被环境变量改变，不能仅凭默认目录判定来源；旧持久化 session 状态也不能证明活跃任务。尚未发现已核验、仅返回状态的外部只读接口。
- TRAE SOLO：已确认内置 Agent 引擎，尚未确认可用于此功能的外部状态/hook 契约。应用常驻不算任务运行。

## 验证与研究边界

- `build/KA1Validation/local-source-tests.log`：34 项测试通过（16 引擎、4 事件工具、7 接入、7 本机来源）。
- `build/KA1Validation/local-source-final-tests.log`：异步等待修正后 7 项本机来源测试再次通过。
- 覆盖：原 17 项保留、27 项唯一 ID、CLI/桌面分离、端口归属解析、响应契约和正文投影拒绝、跨会话优先级、模拟 600 秒运行刷新、等待后 30 秒释放、断开在途请求作废。模拟长任务不等于真实 Kimi 长任务验收。
- 原生预览已检查来源数量、分别列出的 CLI/桌面、只读确认和空闲状态。空闲时 `pmset -g assertions` 未出现本预览的 SuperIsland 保持断言；系统其他应用的断言不归本功能释放。
- REA 对四个 ASAR 的严格分析因 unpacked 原生依赖声明哈希与实际值不符而停止；不能据此判断应用被篡改，也未拿失败的分析图作证据。后续仅检查已安装 bundle 的 JavaScript 文本；未执行抽取脚本、修改原应用或读取真实会话正文。

## 后续验收

1. Kimi 单会话运行 → 等待 → 释放，以及再次运行；逐步观察原生状态和本功能持有的 IOKit 断言。
2. 多会话及同会话后台任务、权限等待、手动中断、退出/重启、接口失联与未知版本。
3. 逐一补足其他本机来源的明确状态契约与客户端身份，再开放候选入口并做真实任务测试。

没有将测试夹具、安装存在或按钮可见计为任务来源端到端支持；没有更改真实第三方 hooks、授权、合盖电源状态或远端仓库。

## 18:04 真实任务复测：未通过

用户在 Kimi Code 发起约定的 `sleep 60` 测试。原生界面显示该工具正在运行，但隔离预览仍显示旧的“空闲”，`pmset -g assertions` 没有本功能保持断言。不能计为运行/等待验收通过。

两个已证实的问题：

1. 当前安装版本已从初查的 1.0.1 变为 1.1.1，运行进程也已更换。进程所属回环端口的同一精简查询分别返回 404 和 401；旧端口已不可用。未使用、提取或绕过新版接口认证，未将其响应映射为空闲。
2. 对旧预览取样发现，端口发现停在 `NSConcreteTask.waitUntilExit`，并无仍存活的 lsof 子进程。原实现运行子进程后在 Swift Task 中 await，后续等待可能切到另一线程；这与实际卡住堆栈吻合。修正为同一后台线程执行进程生命周期，并加入独立 20 秒轮询超时、取消代次和旧结果拒绝。直接读取磁盘 Info.plist，避免 Bundle 缓存保留更新前版本。

验证：`build/KA1Validation/kimi-refresh-tests.log` 的 10 项本机来源测试全部通过；包含重复调用真实 lsof、磁盘版本就地更新，以及超时后旧结果不能覆盖新结果。重建到 `build/KA1LocalSourcePreview-r2`，保留旧预览目录；原生界面已显示“Kimi 当前版本尚未核验；未读取任务接口”。预览总开关恢复默认关闭，无本功能断言。生产 App 和 Kimi 配置未改。

剩余：为 1.1.1 找到明确授权且可区分真实工作/等待的接口，完成适配后重新进行真实任务测试；1.0.1 的空闲响应记录不能升级为 1.1.1 支持结论。

## 暂缓接入验证

`kimi-deferred-tests.log`：11 项中 9 项通过、2 项依赖启用 Kimi 的历史回归按暂缓决定跳过，0 失败。新回归确认旧连接不恢复、直接接入被拒绝、轮询次数为 0。原生 r3 已确认桌面和 CLI 均显示“暂缓接入”且没有接入按钮。总开关关闭，生产 App 未替换。

## 18:29–18:40 官方 hook 实测（本轮，尚未完整接通）

本轮优先使用官方 hooks，未绑定 IDE 精确版本、内部 JavaScript 文件名或本地私有 HTTP 接口。应用进程仅用于对收到的事件归属，绝不作为运行任务的证据。Kimi 两种形态继续暂缓。

| 桌面来源 | 真实事件证据 | 尚缺证据 |
| --- | --- | --- |
| Qoder CN 0.4.7 | 用户发送测试并允许 Bash；收到 SessionStart、UserPromptSubmit、PreToolUse Bash、PermissionRequest、Notification、PostToolUse Bash、PreToolUse AskUserQuestion | 权限请求到工具结束约 66 秒之间，没有授权通过后的恢复事件。不能保证等待 30 秒释放后在授权瞬间恢复；没有静默长任务心跳 |
| WorkBuddy 5.8.3 | 用户授权代操作后新建固定测试；原生界面显示 sleep 60 执行，收到 UserPromptSubmit、SessionStart、PreToolUse / PostToolUse Bash、Notification | 本次初版探针没有保存 notification_type，因此不能把该条 Notification 追认为等待事件；需要重复确认提问/恢复/结束及健康信号 |
| ZCode 3.16.2 | 用户授权代操作后新建固定测试；原生界面显示 sleep 60 执行；收到 SessionStart、UserPromptSubmit、PreToolUse / PostToolUse Bash、PreToolUse AskUserQuestion、PermissionRequest | 问题回答后的恢复、结束、静默长任务和不同权限模式仍待核验 |
| TRAE SOLO CN 0.1.49 | 保留已安装与候选协议研究结果 | TRAE IDE 的公开 hooks 文档不能证明当前 SOLO 版本支持；尚无当前运行时的完整信号 |

Qoder / WorkBuddy 的事件父进程可归属对应桌面应用。ZCode 重写进程显示名称导致初版 argv 匹配漏判；随后改用系统 proc_pidpath 查询实际可执行文件，PostToolUse 和 AskUserQuestion 事件都确认父链属于 dev.zcode.app。正式候选代码同样使用实际路径和 bundle ID，并拒绝带控制终端的父链。尚未单独安装/运行这些品牌的 CLI，不能从桌面测试扩展 CLI 支持结论。

代码增加 KeepAwakeHookContract，忽略额外字段和版本字符串，拒绝缺少会话或未知事件；SessionStart 不创建运行，子任务结束不代表父任务结束，Stop 仅映射空闲；WorkBuddy 的 agent_needs_input / agent_completed 类型依据本机随附协议枚举建立候选映射，未反推为已实测。Qoder / WorkBuddy 的配置合并分支有测试，但注册表仍不开放接入；ZCode 未添加正式配置安装器。

临时探针只保留事件类型、字段名称、时间、布尔会话存在值及允许名单中的工具/通知类型和应用身份，不保存 prompt、正文、session_id、参数、环境变量、认证信息或会话路径。每个探针目录限制 100 条，文件 0600。三份配置均有原始备份，安装清单位于 build/KA1Validation/*-probe-install.json。临时配置的最终恢复状态见后续记录。

构建与回归：stable-hooks-final-tests.log 首轮 17 项通过，涵盖事件映射、未知事件拒绝、等待/中断/结束、跨客户端身份、版本扩展兼容、配置幂等合并及保留其他 hooks。后续小修会复跑相关组。没有替换生产 SuperIsland、安装合盖 helper、改变电源配置或推送远端。测试期间 Mac 锁屏，原生工具要求人工解锁；不能将未观察到的提问界面或结束状态计为验收。

官方协议参考：[Qoder hooks](https://docs.qoder.com/cli/hooks)、[Qoder CN 配置](https://docs.qoder.cn/cli/settings-reference)、[CodeBuddy hooks](https://www.codebuddy.ai/docs/cli/hooks)、[ZCode hooks](https://zcode.z.ai/en/docs/hooks)、[TRAE IDE hooks](https://docs.trae.cn/ide_automate-actions-with-hooks)。配置兼容不代表任务状态完整；官方协议也可能演进，不能保证所有未来升级免维护。

本轮收尾：最终协议/事件工具/配置回归 17 项全部通过。按精确命令移除 Qoder 10、WorkBuddy 10、ZCode 7 个临时 hooks；三份设置回读均与各自原始备份逐字节一致。三个探针目录已写入禁用标记，已打开会话即使缓存旧 hook 也不会继续记录。原始备份仍保留，恢复清单见 build/KA1Validation/probe-cleanup.json。界面后半程因锁屏未验收；测试任务的提问待解锁后核对。

## 23:14–23:18 解锁后续测

用户授权直接操作持续有效，并明确回复已解锁。当前界面确认 WorkBuddy 第一轮一直停在提问等待；ZCode 第一轮已自行结束，回复未收到选择。后者仅是界面观察：第一次结束时探针禁用，不追补结束事件证据。

两款分别进行了短任务：提问是否执行 sleep 10，选择执行后运行并结束。两边原生 UI 均显示验收结束，探针观察到：

- WorkBuddy：UserPromptSubmit → SessionStart → Notification(permission_prompt) → 用户选择后 PreToolUse(AskUserQuestion) / PostToolUse(AskUserQuestion) → PreToolUse(Bash) → 约 11 秒后 PostToolUse(Bash) → Stop。另在第一轮选择暂不继续后收到 Stop / SessionEnd。注意此版本提问的 PreToolUse 在用户回答后才出现，因此等待必须使用 Notification，不能只监听 PreToolUse。
- ZCode：UserPromptSubmit → PreToolUse(AskUserQuestion) → PermissionRequest → 用户选择后 PostToolUse(AskUserQuestion) → PreToolUse(Bash) → 约 11 秒后 PostToolUse(Bash) → Stop。

新增回归将这两种实际事件顺序送入纯策略引擎：等待 30 秒释放，回答后重新运行，Stop 后 30 秒释放且不虚构成功完成。hook-resume-tests.log 最终 18 项通过；纯引擎回放不是原生 IOKit 端到端验收。注册表文案更新为提问、恢复与结束已实测，自动接入仍关闭，静默长任务健康信号和一般工具授权恢复仍未闭环。

临时配置再次备份后窄合并；收尾移除 WorkBuddy 10、ZCode 7 个探针 hooks，两份配置与本轮各自原始备份逐字节一致。缓存探针再次禁用，恢复清单 build/KA1Validation/probe-round2-cleanup.json。没有改动权限模式、生产 App、合盖服务、正式 PRD/标注或远端仓库。


## 2026-10-28 WorkBuddy 最终停止与 ZCode 漏采修复

本轮为已确认 KA1 需求的实现修正，未改变界面、正式 PRD、HTML 或 annotation 映射。

- ZCode 3.16.3 本机原有六条自有配置含空 matcher；已安装代码的配置 schema 要求该字段非空或省略，旧配置因此不能加载。源码安装器原已省略 matcher，本轮经用户明确授权备份并仅删除这六个旧空字段，语义回读确认其他配置不变。新会话 sleep 60 实测，当前已安装 20261028000455 收到 zcode-desktop 的 startsTask/running、工具前后 running、Stop/idle；开始归属已恢复。这份实测属于配置修正与旧 App，不冒称新候选已验收。
- ZCode 原生 hook 保留 camelCase turnId；新增按其哈希隔离任务轮次。Stop 后仍可自动继续，维持 idle；不伪造该来源不提供的 FinalStop/SessionEnd。自动完成仍未获证明。
- WorkBuddy 5.9.3 本机随附实现有 FinalStop，发生在 Stop 的继续判断之后。agent_completed 仅找到枚举，未证实它被实际分发；不能靠它补完成。本轮安装器为 WorkBuddy 单独添加 FinalStop、PreCompact、PostCompact；本机这三项写入已获用户分别明确授权，安装阶段再执行并回读。
- FinalStop 仅在同会话/同 generation 的明确开始准入、相同 agent_id 和 agent_type、显式 is_truncation_recovery=false 及允许的结束原因下映射 completed/failed/cancelled。角色尚未赋值时，只允许本任务 actor 的首个工具前事件补齐。身份摘要保存在私有目录，受有界容量、文件/所有者/权限校验与锁保护；任务正文、工具输入输出与凭据不写入该证明。
- PreCompact/PostCompact 均为该 generation 建立保守阻断，包括先于延迟开始到达的边界。当前协议不能完整证明压缩后的主任务最终结算，因此本轮不靠 PostCompact、计时、Stop 或丢失恢复信号解除该阻断。普通任务完成修复与压缩任务仍待核实必须分开报告。
- 最终校验和已认证终态入队在同一证明文件锁中执行；仅在成功投递终态后清除对应准入，迟到旧轮次不得结束新任务。存储不可用仍上报真实 running，但不能上报未经证明的完成。

隐私与证据：只分析自有 hook 配置、随附应用协议实现、匿名任务事件和功耗。静态随附代码证据不等于真实 IDE 验收；本轮证据存于忽略的 build/WorkBuddyZCodeRepair.noindex，用户旧挂绳内容、其他任务、系统信任与权限保持原状。

首轮安装后的真实 WorkBuddy 新会话揭示补充边界：新 root 可尚无 durable storeId，agent_id 字段缺省。20261028100521 收到了实际开始、60 秒工具和两条 idle，未建立 actor 证明，未算通过。后续修正允许明确开始的同会话/同轮次在 actor 字段始终缺省时建立证明；空字符串、null、非法类型不是缺省；一旦出现其他 actor 或角色不一致仍不接受完成。新增真实首轮形态的回归，并将失败证据保留在独立文件，后续候选需重新备份安装实测。
