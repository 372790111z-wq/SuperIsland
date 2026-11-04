# KA1 本机新增来源核验

> 最新决定：用户要求先不接入 Kimi Code。桌面/CLI 两项暂缓，实际测试连接已断开；源码禁止接入、启动恢复及轮询。保留以下历史证据，停止 Kimi 适配和验收；其余来源范围不变。当前标注归档 20261021-3。

日期：2026-10-21；分支：`feat/keep-awake`。本文件记录实施证据，范围和默认行为以 [KA1 PRD](product-package/06-SuperIsland保持唤醒PRD-KA1.md) 为准。

## 2026-11-04：自然合盖实机验收

安装版 20261103142646 在同一新进程内完成开盖及自然合盖实测。开盖时，最后一项已识别任务进入终态约 33 秒后，确认保持及系统禁睡均已释放。

- **合盖保持通过**：08:58:33 确认合盖，仍有任务运行，保持继续生效。
- **自然释放通过**：最后一个 ZCode 任务于 09:00:24 进入明确失败终态，待处理任务随后归零。约 34 秒后，仍处于合盖状态，App 确认合盖保持与系统禁睡均已释放。
- **实际休眠通过**：SuperIsland 于 09:00:56 发起休眠请求，macOS 记录同一 App 进程于 09:01:01 触发软件休眠，至 09:09:30 开盖唤醒共 509 秒。
- **后台唤醒后再次休眠待验收**：本轮只观察到最后的开盖唤醒，未触发后台醒后的再睡路径。

时刻使用北京时间。原生采样和系统日志仅保留本机。

## 2026-11-03：主线整合验证

保持唤醒修复与 GitHub 已有的截图去重修复合并后，最终完整回归 1256 项、2 项既定跳过、0 失败；独立验收脚本 25 项通过。整合修正只涉及测试兼容性：主开关测试使用确定且不同的图片验证重新启用后的采集，HUD 测试允许既有媒体已经占据同等宽度，并继续要求刘海两侧安全空间及不缩窄。首轮的旧测试假设和前台前提失败日志保留，最终完整重跑通过。

电池管理分支未提交工作未合入本次发布；共享 helper 与该分支协议的离线组合类型检查通过，共享文件三方合并预演无冲突。未安装或重新启动产品，未恢复自动跟进；最新物理验收见 2026-11-04 记录。

## 2026-11-03：内核睡眠证据与后台维护诊断修复

回顾此前依赖 willSleep/didWake 通知配对，真实系统日志中三段睡眠只计入一段。现在将既有公开内核 sleep/wake pair 传入当前回顾，在保持重新接管及开盖边界补记同周期真实睡眠和仍合盖唤醒，并与通知去重。旧/未来/倒序 pair、重启中断及冻结后的事件不得回填历史；去重仅保留有界证据，时间线与存储上限不变，兼容旧数据。

长后台清醒区间存在系统 BackgroundTask CPU 阻塞。保留原有 CPU、任务、来源新鲜度、helper 释放和物理电源守卫，仅增加聚合阻塞类型和自然解除记录，不持续采集进程名或断言描述，不强制解除外部断言，也不承诺消除所有系统维护唤醒。请求受理、实际入睡、后台醒来后再次请求及实际再睡分别验收。

本次固定源码完整回归 1255 项、2 项既定跳过、0 失败；含回顾/收尾 118 项和 13 项新增反例。第一次全量中的截图测试遇前台前提竞态，原日志保留，单项及完整重跑通过。安装前完整备份旧版 20261102143113，安装版为 20261103142646；helper、事件工具和 launch plist 未替换。原始证据保留于本机 `build/DarkWakeRecapRepair.noindex`，不将任务身份或设备采样上传至代码仓库。

**当日验收状态**：本版本真实开盖保持已观察 255 秒；自然释放等待中主进程退出，原因未确认，自动跟进已停止。本版本自然释放、合盖保持及后台醒后实际再睡均未判通过。先前版本的开盖释放证据不能替代本版本物理验收，历史回顾不重写。

## 2026-10-30：低电量模式恢复与辅助程序恢复一致性

用户授权在不操作其他任务的前提下修复，测试通过后先备份再安装。这里只对自动模式的纯低电量模式保护增加安全自动恢复，不改变热保护的手动检查要求，不切换系统低电量模式做实测、不修改 `pmset` 或外部 hooks/信任。

- **真实触发/退出**：powerd 记录 10-29 17:49:48 切到电池后 LowPowerMode 从 0 变 1；18:12:54 接电后从 1 变 0。App 保护仍锁存至次日。旧 Engine 将一切保护永久保存，仅显式 resume 可清除，且低电量原因会覆盖此前热保护原因。
- **自动恢复修正**：仅 enabled/automatic/未暂停、纯低电量保护、当前电源/电池/热状态全安全时，连续稳定 30 秒后调用已有 owner 校验恢复流程；helper 尚未确认、当前变热、用户关闭/暂停/改模式、代次变化或时钟异常均不清保护。最多 3 次检查、失败后 60 秒退避。实际睡眠间隙不计入稳定期，恢复回包跨睡眠后也重等新安全窗口。手动计时与热/未知/低电量阈值等保护不自动解除。低电量不再覆盖严重保护记录。
- **恢复记录修正**：已有本人租约续租时若全局值已回原 baseline，旧代码误报 conflict。现在仅清除经验证的自有记录、准确提示系统/其他工具已恢复，不在该续租中强写 1。未知值、损坏记录、不同 owner 不清、不覆盖。过期恢复真实完成才返回成功，daemon 据此清除过期错误；未恢复或失败仍保留错误/意图。
- **安装生命周期缺口**：内核只读 CDHash 显示 root helper PID572（10-26 启动）为 `6b9f849b…`，磁盘包 helper 为 `1ce117f8…`，替换 App 没有替换常驻二进制。不同摘要证明旧程序仍运行，不代表每条语义均不同。安装需要用 App 自身 owner 确认释放后正常撤销/重新注册已有 helper，并在新 PID 上核对内核 CDHash 与新包一致，不能只核对 App 版本。采用 [SMAppService 官方生命周期](https://developer.apple.com/documentation/servicemanagement/smappservice)，不强退或改系统信任；若系统要求新授权则由用户处理。
- **诊断边界**：root 私有 lease.json 未越权读取，因此历史第一个 conflict 具体由哪次外部重置/读回竞争触发仍未知，不归因特定程序。只确认并修复可复现的错误分类、错误锁存和更新未验证运行二进制问题。现有原生采样补低电量、helper enabled/release pending/failed；当前/最近合盖周期仅保存首次低电量保护观察时间，旧摘要兼容，不记录任务正文。

验证与安装结果分别记录在 `build/PowerRecoveryRepair.noindex`。代码回归不代替低电量实机切换或物理合盖验收；不把重启清账本当任务结束自动释放。

## 2026-10-29：热保护与完成后再次休眠解耦

本次只修改源码并进行隔离回归，不更换正在运行的安装版，不清除保护、不发起真实睡眠或操作其他任务；WorkBuddy 保持断开。

- **证据**：版本 20261028174640 / PID 37463，本轮 11:52:06 首次 Software Sleep；12:02:01 rtc/Maintenance 后台醒来；12:03:28 本 App 释放保持断言；12:03:50 powerd 收到 DarkWake Thermal Emergency；12:03:51 Thermal Emergency Sleep。之后无第二次本 App Software Sleep。后续系统自行热紧急/维护休眠不能算本 App 再次请求通过。
- **热保护原因及未知**：保持策略直接采用 Foundation `thermalState` 的 serious/critical，任一条件会锁存停止保持。系统日志另有热紧急信号，并非本 App 将任务超时误作发热。但当时有限原生采样已到期，无法还原热等级首次变化时间、具体等级、温度或致热进程；开盖后 nominal 不能反推历史。Apple 对该 DarkWake 消息的定义见 [官方说明](https://developer.apple.com/documentation/kernel/kiopmmessagedarkwakethermalemergency)。
- **代码根因**：旧完成休眠策略将所有保护都映射到 inactive，热锁存连带清除了再次休眠资格；背景醒来后的新工作也清除已受理批次，并要求新工作重新取得 helper 保持。若随后热保护阻止保持，任务即使有真实终态也不能重新武装请求。精确的运行时内部布尔值未被当时采样保存，不能声称已逐秒还原；旧代码的热 veto 已由先失败的回归测试复现。
- **修复**：热保护继续禁止保持，降温也不自动恢复。完成休眠策略单独检查非热电源条件；仍须已有真实保持、所有已监测任务明确终结及 30 秒宽限、断言/helper 已确认释放、闭盖且外屏 0。对已受理请求并实际观测到双时钟睡眠间隙的同一闭盖周期，保留仅供热保护使用的醒来上下文；新工作结束后才可再请求。普通新工作仍需自己的真实保持，未知、Stop、失联、来源断开或重启不作完成。
- **边界**：开盖、外接/未知物理状态、关闭/暂停/手动、非热保护、来源变更或释放失败取消资格。每次请求消费资格；受理而未实际睡眠不会反复请求，跳过/失败也不循环重试。每次真正再醒来仍重新等待 30 秒并核对来源刷新及释放确认。
- **诊断**：现有私有回顾文件仅增当前/最近周期的首次热保护观察时间与当时 Foundation 等级，旧文件可读；首次观察不冒称发热起点，不记录温度、进程归因或任务正文。首次观察立即落盘，其余沿用有界检查点。验收采样增加热状态字段，未新增常驻进程或轮询频率。

最终回归 1175 项，2 项暂缓 Kimi 测试跳过，零失败；完成休眠策略 35 项、回顾 39 项均通过（本轮新增 9 项）。Release 编译通过，未进行签名打包或安装。两次完整回归保留了既有音量尺寸测试的失败证据：媒体已占刘海两侧时基线与提示同宽，原测试错误要求继续增宽；仅修正为不缩小、保有相机间隙外空间并恢复原尺寸，未改业务行为。独立音量测试 11 项及最终全量均通过。

验证和设备边界见本机 `build/WakeResleepValidation.noindex/ThermalResleepRepair/verification.json`。源码通过不代表已安装，也不代表后台唤醒后的真实再次入睡通过；此前物理测试失败/未覆盖的结论不改写。

## 2026-10-28：Codex 精确轮次元数据补齐终态

本轮物理合盖 15:59:19—16:15:19，保持生效但没有休眠。精确匹配的 Codex 主轮次在 15:21:02 已 `failed`，却仍在 hook 账本中未结束；官方轮次元数据与本机状态表的五列交叉确认。此结果不能算自动释放或再次休眠通过，低电量模式保护导致的释放也不能冒充任务完成。证据位于 `build/WakeResleepValidation.noindex/Installation/PhysicalLidValidation-20261028-155615/acceptance-result.json`。

用户已明确允许 SuperIsland 持续只读 `~/.codex/thread_history_1.sqlite` 的 `thread_turns` 五列：`thread_id`、`turn_id`、`status`、`started_at`、`completed_at`。授权以本机 App 的 `keepAwake.codex.turnMetadata.v1` 显式开关保存，默认关闭；原有 hook 连接和其他设备不能隐含取得授权。读取和应用异步结果时都重新检查授权。

- 仅对已接入 hook 来源、已绑定获准的默认 Codex home、已经收到真实运行事件且尚未结束的具体主轮次查询。只匹配会话和轮次匿名身份，不从历史数据创建任务，也不改读其他自定义环境。
- 将精确 `completed`、`failed`、`interrupted` 分别补为完成、失败、取消；`idle`、Stop、缺行、未知状态、异常时钟、锁冲突、损坏或读取失败均不构成结束。
- 主轮次结束不替辅助压缩任务制造结束；新轮次不能借旧轮次终态释放。应用结果前核对来源代次、环境、精确身份和原事件序号，断开来源、换环境或查询期间新事件到来会丢弃旧结果。保留正常 30 秒释放宽限。
- 与 ZCode 复用一个固定 schema 的只读 SQLite 安全内核，保留各自终态映射和秒/毫秒单位。使用只读/NOFOLLOW、同 UID 和 sidecar 检查、五列 authorizer、私有列/视图拒绝、指令及最长 250 毫秒预算。Codex 先按会话索引分组筛选再匹配轮次，避免对约 1.3 万条历史逐轮计算哈希；有候选时最多每 5 秒一次、utility 异步读取，无候选不打开数据库。
- 不读取 `thread_items`、`error_json`、正文、工具内容或凭据，不修改 Codex 配置、权限、任务状态和数据库。WorkBuddy 继续不监控。

新的生产读取器已在同一真实失败轮次上只读匹配成功，返回 `failed` 和原始开始/结束时间，本次约 68 毫秒。该证据不是对已安装旧版账本的手工修改或自然释放验收；正常安装重启同样不能证明旧记录自然清除。

最终 macOS 回归 1166 项，2 项暂缓 Kimi 接入测试跳过，零失败。新增 19 项覆盖五列投影、WAL、精确失败旧轮次、并发新活动、断开及授权撤回、辅助任务隔离和 30 秒释放。一次完整回归中的既有音量提示尺寸测试曾受共享媒体状态影响失败；未修改该功能或测试，独立复测及完整重跑均通过。日志和真实只读验证保留于 `build/WakeResleepValidation.noindex/CodexTerminalRepair`；Release、签名打包、安装与物理验收分别记录，不用代码回归代替设备结果。

## 2026-10-28：合盖后台唤醒后的再次休眠

本次用户明确授权：仅合盖且已监测任务都明确结束时，在后台唤醒后再次请求系统休眠；开盖遵循系统策略。此处是现有电源策略的内部修正，不新增设置或界面。WorkBuddy 保持断开，不扩大数据读取、hook 或授权范围。

- 只有本进程确实持有过本轮合盖保持、全部已监测任务有明确终态且宽限结束，才有首次请求资格；历史终态、来源断开、重启或无任务初始状态不能取得资格。
- 系统接受首次请求后，仅在连续时钟与 awake 时钟显示实际睡眠间隔大于 1 秒时保留唤醒后复核资格。复用现有一秒 tick，独立于 NSWorkspace 唤醒通知；定时器阻塞、时钟异常、仅接受请求但未睡眠不会启动重试。
- 每次真实醒来重新等待 30 秒，复核任务终态、最新物理状态和本功能的保持释放确认。已接入的 Codex RPC / 本机状态采样必须有醒来后发起的有效查询；查询失败、部分或未知状态不能用旧结果批准再次休眠。钩子来源继续使用原有真实事件账本；ZCode 仍只读取已获批准的精确轮次状态元数据。
- 开盖、外接屏出现或物理状态未知会取消旧批次资格，随后再次合盖不能恢复旧请求。新任务到来撤销旧的唤醒请求资格，按新任务的真实保持、终态及宽限重新判断。关闭、暂停、切手动、非热保护或来源变更沿用取消资格规则；热保护的完成后再次休眠例外见 2026-10-29 节。
- 每次真实睡眠后的醒来最多请求一次。失败或请求被系统接受但未实际睡眠时，不每秒反复请求。再次入睡后又醒来可重新复核；资格仅在内存中，不跨 App 重启恢复。
- 使用原有用户态系统休眠请求；不改 pmset、系统信任、来源配置，不结束应用或剥夺其他应用断言。休眠可能暂停未监控任务、下载和远程连接，属于用户已确认的合盖政策边界。请求接受与实际休眠仍需分别验证。

最终 macOS 回归：1147 项，3 项跳过，零失败；其中休眠策略 28 项通过（新增 15 项），覆盖重复真实睡眠/后台唤醒、30 秒复核、延迟通知、开盖/外屏/未知物理状态、新任务及未知任务、释放未确认、来源未刷新、拒绝/未实际睡眠不循环、时钟异常与保护取消。最终 Release 编译通过（本轮关闭构建签名，不是可安装候选的签名验收）。跳过项为暂缓的 Kimi 接入 2 项及当前测试显示环境不具备刘海区域的 1 项。测试记录保留在 `build/WakeResleepValidation.noindex/verification.json`。代码测试不代替本机合盖、后台唤醒及再次实际入睡验收。本轮不替换正在运行的安装版。

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


## 2026-10-28 ZCode 精确轮次终态与 WorkBuddy 压缩收尾复核

ZCode 在 Stop 及后续继续全部完成后，向本机 `turn_usage` 写入精确 `(session_id,turn_id)` 的终态。用户明确允许只读五列：session_id、turn_id、status、started_at、completed_at。新增读取器只匹配已认证开始的匿名身份，不读取其他业务列/表，不保存原始 ID；无行、未知状态、错误、路径覆盖或结构变化保持未知。只读 SQLite、同用户普通文件/侧文件、符号链接拒绝、SQL 授权器列白名单、运行预算及异步五秒调度共同限制访问和开销。断开/关闭后的迟到结果不能重建任务；未进入查询快照的新轮次不能被旧结果结束。

11 项读取专项与包含服务调度的 20 项回归通过；全套 1131 项、2 项原有跳过、零失败。编译后的生产读取代码只读核对之前获授权的真实 ZCode sleep60 测试，精确读到 completed，单次约10毫秒。上述证明是代码/状态读取证据，尚非已安装服务自动释放证据。

WorkBuddy 桌面真正完成信号在 ACP executePrompt 完整运行及事件转发之后，但当前未找到可安全被动接入的精确请求生命周期通道。会话数据库状态可由手动/恢复流程改写且缺少 generation，普通历史没有通用终态；实时 bus 无生命周期字段过滤，且要求绑定 ACP 会话。新建/恢复连接会初始化和绑定会话，不能保证不影响现有任务，因此未接管或接入。压缩后 FinalStop 仍维持未知，不能称完整修复。

本检查点保存源码修改及 build/WorkBuddyZCodeRepair.noindex/FinalSettlement 证据；未构建/安装新包，当前本机仍为20261028101328/PID71143。未变更来源配置、信任、权限或其他任务，未通过全任务自然释放或物理合盖验收。


继续静态调查补充：已明确构造乱序反例——压缩内部Stop聚合晚到，FinalStop从恢复后的可变session取身份，故SessionStart(compact)或恢复后首个工具不能解除压缩保护。新增反例与相关48项回归零失败，仅证明保守安全性。只读HTTP/SDK状态不含完整dispatch屏障；强ACP结果事件仅发远端Galileo，当前没有不重定向其他遥测的本地独立导出入口。完整调查与最小安全出口要求见build/WorkBuddyZCodeRepair.noindex/SafeWorkBuddySettlement；WorkBuddy完整收尾、安装及自然释放仍未通过。未改WorkBuddy配置、信任、任务或现有App。


用户随后调整交付范围：WorkBuddy问题暂缓，保留保守保护且停止监测WorkBuddy；单独交付ZCode修复，测试后备份安装并验自然释放。已通过当前App原生来源页断开WorkBuddy，14条自有hooks移除，非自有hooks及其他设置语义回读不变，原配置0600备份；此动作不是任务完成或自动释放证据。新阶段为build/WorkBuddyZCodeRepair.noindex/ZCodeOnlyValidation。用户另要求其余监测任务结束后请求系统休眠；请求与实际睡眠分别验收，常规行为范围另行澄清。


## 2026-10-31 AlDente 合盖控制冲突修正

用户明确批准：检测到运行中的 AlDente 时阻止合盖启用，退出后须显式恢复；不操作 AlDente，不影响普通防休眠和任务监测。沿用 KA1-F09 及当前标注 20261026-5 的 si.ka.lid / si.ka.recovery 状态入口，不新增页面或改变终态判断。

- KeepAwakeLidClient 仅读取已知 bundle ID 与已安装 helper 的运行路径；App 启动通知覆盖定时检查之间的短暂运行，helper 存活期间也继续拦截。只安装而未运行不构成冲突；进程清单读取失败仍为未知，不当作无冲突。
- 授权、保存意图恢复、状态/续租在途回复及显式恢复均核对冲突。已拥有或可能已拥有的租约仅按本 owner 释放，保留未确认恢复，不反复抢写。释放在途不会被取消。
- 冲突锁定同时清除下次启动自动启用的保存值；竞争者退出不会自动启用。低电量自动恢复不得解除冲突锁定，只有显式恢复或重新启用可继续。
- 检测本身不启动/退出其他应用，不读其他应用设置、消息、工具内容或凭据，不改变限充、信任及权限。
- 证据：build/LidResetAttribution.noindex/attribution.json（静态退出清理与两次历史时序）、Repair 下的回归与安装回执。历史物理合盖失败仍保留；本次新安装及开盖稳定不替代真实合盖/释放/休眠验收。


## 2026-10-31 后台 CPU 断言暂缓休眠修正

历史powerd将75分10秒的BackgroundTask归于dasd PID392，公开活动标识com.apple.Safari.SafeBrowsing.BrowsingDatabases.Update；对应断言47244676728在14:05:49.754释放，14:05:49.769系统进入维护睡眠。内核12:51:10因kPMCPUAssertion取消当时的睡眠转换。不能据此强制结束Safari/系统维护或声称可以消除维护自身的占用时长。

- 生产Snapshot从已有IOPMrootDomain读取DriverPMAssertions，以公开kIOPMDriverAssertionCPUBit只判CPU位；MAGICWAKE等其他位不误判，缺失/损坏/布尔/非整数读数保持未知。只读数值，不列出其他应用断言名、正文或工具内容。
- 任务明确终结、约30秒释放后，CPU阻塞或未知时等待，保留原有合盖请求资格；CPU位解除后仍检查开盖、外屏、来源新任务、释放确认及原有唤醒宽限。最终二次快照出现CPU阻塞仅暂缓，没有实际API调用。
- 已受理/失败仍不能触发重试循环，不覆盖系统拒绝或他人断言。等待期间开盖/停用/新未保持任务不能复用旧资格；系统先自行睡眠后仍要求真实双时钟唤醒证据、新30秒宽限及来源更新。
- 回顾时间线记“系统CPU保持尚未释放/状态未知，休眠请求暂缓”；不标为请求已接受、保持失败或真实睡眠。不新增页面、不改PRD、标注沿用当前20261026-5的既有状态/时间线入口。
- 验证文件在build/CPUAssertionRepair.noindex；隔离回放4510秒不是真实设备试睡，不影响正在运行的App或其他任务。本轮验证不据此宣称物理验收通过。


## 2026-11-01 用户态 CPU 聚合断言与未入睡恢复修正

本轮真实后台断言47244679238由dasd PID392持有，公开活动为com.apple.Safari.SafeBrowsing.BrowsingDatabases.Update，持续96分17秒，14:29:49释放。12:54:01.453请求已受理但kernel以kPMCPUAssertion取消dark->sleep，直到开盖未再实际休眠；不推断Safari内部为何如此耗时，也不结束系统维护任务。

- 根因：XNU仅将assertionsKernel发布为DriverPMAssertions，实际CPU判断使用kernel与user合并结果。上版仅读驱动位漏掉powerd的BackgroundTask。现在仅在合盖且SleepDisabled已恢复时，通过公开IOPMCopyAssertionsStatus读取七类CPU断言的聚合0/1，合并驱动CPU位；不读取进程、断言名/ID/描述。idle/display不误判为CPU，缺类型/失败/损坏保持未知。
- 请求与CPU快照不能原子化。对于已受理却未实际睡眠，仅观察到后续明确CPU阻塞及其明确解除，才保留该真实已持有任务批次的一次重新核验资格；重新等待30秒、刷新来源并确认自有断言已释放。受理、willSleep通知或时间流逝自身仍不能触发循环重试。
- 开盖、外屏、停止、全局SleepDisabled未知/被占及新未保持任务撤销旧资格；真实睡眠后仍用双单调时钟与新宽限。现有热保护、低电量、AlDente冲突与外部任务安全边界保留。有限匿名功耗记录增加CPU聚合判定字段，未知仍写null；回顾继续复用既有暂缓/受理/实际睡眠时间线。
- 沿用当前20261026-5、si.ka.lid/si.ka.recovery与已确认KA1/KA2；B类型实现修正，不新增页面或重写PRD。新增真实96分钟重放、所有CPU类型/坏值、受理后CPU竞态、释放后30秒和来源屏障、取消/新任务/睡醒等回归；完整日志及包/安装证据在build/CPUAssertionAggregateRepair.noindex。测试与安装不替代新一轮物理验收。
