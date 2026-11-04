# 单次暂停刷新候选（2026-11-03）

状态（2026-11-04更新）：昨日固定包已获批准并成功启动；准备阶段发现故障后旧心跳重放，停止硬件试验并完成源代码修正及独立复审。新版最终全量1814项（2既有跳过）零失败、三构建通过，已安装，新后台已获批准并核对运行身份；用户手测原生85→80放电及目标停止通过。一次供电切换未执行。此文不代表暂停硬件验收。

## 原问题与范围

既有实机79%充电中暂停失败：偏好已保存，但PowerUI未立即处理同SOC的非强制刷新。官方客户端enableMCL固定80、同值setter可能返回，IOKit直接登记需要私有entitlement，不能作为自有实现绕过。

用户本轮明确授权：约500ms供电切换，先实现并审查，然后仅一次79–85%内验证；需人工插拔才恢复即判自动恢复失败。

## 最小候选及安全责任

- 仅BATTERY_REVIEW且签名包BM1PauseRefreshTrial=true；XPC限定相同证书BM1Debug客户端。生产包不启用。无新增UI图标或原型页面。
- 仅明确paused操作、79–85、有效充电/独立适配器输入、暂停偏好已保存但注册未一致、无校准/竞争控制器。保护/航海/自动放电/LED/能源覆盖需隔离关闭后方可试验。
- root私有目录固定pause-refresh-v1.consumed采用O_EXCL且同步文件/目录；任何已有、空白或损坏记录均视为已消耗。新operationID、心跳、重启及重装均不能重放；不自动删除。
- 硬件原值唯一保留在原lease；cutoff独立记录恢复责任。写8前持久意图，固定SMC command6写8→连续时钟剩余等待→固定command6写0。两条命令之间没有磁盘持久化或传感器查询。命令间隔不等于物理精确脉宽；系统调用不保证硬实时，超过候选时限不计通过。
- 写8丢回复、写0失败、0后日志写失败、重启及退出均优先恢复有可信原值的CHIE0；元数据不可信时不先恢复可能重新影响供电的偏好。外部值冲突不覆盖。
- A：CHIE0读回和独立输入稳定10秒；pulse专属规则不虚构off观察，旧放电恢复仍要求off→on。
- B：暂停目标active偏好/注册匹配、切换释放之后的新IORegistry电池发布上下文、明确未充电及有限电流≤0，稳定10秒。A不是B；暂停成功仅在B成立时报告。
- C：取消/重启允许A→原偏好恢复，不必等待B。A/B使用continuous单调时钟，采样空窗>5秒重置稳定计时。pending先于策略/写入处理，越界不会先写新暂停目标。

## 对抗审查及测试

独立审查代理pause_refresh_static_review，最后已关闭所提P0/P1：写后持久化拖长脉冲、磁盘满阻止释放、active与restored混用、越界先写、新鲜度起点过早、采样空窗、睡眠时钟及底层writer隐藏读操作。XPC已有代码签名要求，审查中“任意非root客户端”假设经完整调用链核实后撤回。

- 全量：1793项，2项既有跳过，0失败（tests.log，早于最后编排修订）。
- 最终定向：38项，0失败（targeted-sealed.log），涵盖16项新候选测试及22项既有cutoff回归。
- 主要注入：保存意图前失败、写8丢回复、写0拒绝/后续watchdog释放、释放后磁盘满、重启磁盘满、已消费/空票据、外部值/owner冲突、慢写不追加等待、固定命令无间插读写、未知/非法电流、旧读数/新鲜度、空窗/时钟、越界不进入apply、取消不等B。
- 修复实测无关的真实解析缺口：NSNumber非有限电流必须保持未知，不允许uint64转换后变成零。

完整运行日志及最终源文件SHA256：build/bm1-pause-refresh/。源码指纹不会取代构建和实机证据。

## 设备与未完成

写代码期间现有安装包未改、主控关闭、系统85%、接电不充电。用户电池偏好与原快照语义相同；原值快照位于build/bm1-pause-refresh/user-preferences-before.plist。

待最终构建后封装/安装，再核对运行helper签名身份；只做已授权的一次受限脉冲，不运行100%/10%完整校准。没有新的实机证据前不能称需求全部完成。

## 固定交付

版本 20261103154439；App 18909900B；ZIP 12073457B；ZIP SHA256 `dd71ceeed98bddc39be8b4aa33e567f21e32dfa02c4173684098912281aabfab`。107个文件与封装源逐个SHA256一致，签名验证通过。相较原包App增加49,644B、ZIP增加20,611B。

安装：/Applications/SuperIsland Battery Review.app

回滚备份：/Applications/.SuperIsland Battery Review.before-pause-refresh-20261103T234504.app

实机脉冲尚未执行，不能称暂停问题已解决。

## 安装后的系统阻断（23:50）

新包签名再次通过；helper CDHash `03a8707f7c45fe955acbf5a9296f8c13156c61ab`。未启动实机脉冲。

首次登记移除了旧job；同包补交后launchd仍引用旧BTM UUID `4A95E42B-8055-4525-BE66-7BF70396A405`，先出现Launch Constraint Violation，后EX_CONFIG。系统产生新记录 `B700323B-F758-4BAF-9687-0F58444A5AFF`，明确disallowed，当前登录项开关off。针对失效旧job的bootout被OS以Operation not permitted拒绝；未绕过权限。只读sfltool超时停止，不把无输出视为无记录。

下一步需本人开启该后台开关。批准后只核验同一包和现存记录，不重装、不清除新授权记录；实测仍仅一次79–85。当前主控off、85%、接电不充电，原偏好保留。


## 2026-11-04：授权已解决；准备阶段暴露新缺陷

- 08:53批准已生效；09:12只补交同包现存登记，helper PID6502运行，kernel CDHash与安装包一致。未再次注销/更换包；原“待批准”记录已被此当前证据取代。
- 原生目标83准备期间，09:18:32观察负电流-932mA，随后进程隔离检查errno3触发恢复；09:19:11恢复后旧心跳09:19:14重新提交放电，证明客户端布尔确认不足。
- 09:21第二次隔离检查失败，设备恢复85%系统基线；暂停脉冲未执行。原生电量始终85%，不能把原始容量变化称为已到83%。
- 用户偏好已与测试前快照逐字段相等（limit80、automaticDischarge/sailing/heatProtection=true、sailingLower70、temperature35）；主控off，系统85%、AC attached、未充电。证据：live-20261104/user-preferences-restored.plist 与 user-preferences-before.plist。

### 本轮修复与反向审查

- helper维护持久manual-retry故障记录：精确故障ID、失败操作拒绝历史、确认绑定、正常释放resolved；未知/损坏不是无故障。保存失败仍恢复硬件，禁止删除唯一恢复日志，watchdog重试落盘。
- protocol17引入每次helper实例epoch；每个renew先验证epoch，旧helper的请求不能跨重启重放。只明确retry/重新启用读取当前故障并携带确认；所有renew响应的故障都关闭控制。
- 确认仅属于准入信封，进入业务策略/恢复比较/完成归一化之前清除；故障后watchdog只恢复，不能绕过入站门禁继续旧策略。
- CHIE紧急释放先于故障持久化；正常确认且验证释放后允许重启自动启用，未确认或未完成的故障仍锁定。
- 进程身份使用内核明确absent/zombie/live/unknown，允许已回收或同一僵尸被回收的证明；保留存活未知身份的封闭检查。历史两个PID已退出，不能把errno3单独认定为该竞态的完整证据。
- 截图的重复授权错误拼接已修复，单独测试确认只显示一次。
- 独立审查pause_refresh_static_review共发现并关闭旧请求重放、写入后失败未重锁、落盘重试、无ID故障、相等性、watchdog绕过、跨重启身份、CHIE释放顺序及正常自动启用问题；最终静态审查无剩余P0/P1。

本轮日志在build/bm1-pause-refresh/live-20261104。reviewed-fault-source-sha256.json固定了已审查源文件。测试和构建只能证明对应层面，不能替代一次受限实机的充电停止/供电恢复证明。


### 固定新候选（已安装，待系统批准）

版本20261104014108，protocol17。ARM、Intel、Review三构建通过；独立静态复审通过。App 18,943,020 B（比旧候选增加33,120 B），ZIP 12,097,266 B（增加23,809 B），SHA256 cce6e61d5a1a87bb7397abd794e5dd69b08314a09b1b3eee496946668f11757c。签名复核通过，审查源指纹无漂移。

第一次最终全量1814项有1项测试替身失败：fake每次回复错误地重新生成epoch，导致同一操作心跳比较不等；修正fake为每实例固定epoch后全量1814项（2既有跳过）零失败。该修正不改变产品源码或放宽安全判断。


### 新包当前安装状态（09:49）

108个文件与封装源逐个SHA256一致；/Applications/SuperIsland Battery Review.app 已更新，旧包保存在 /Applications/.SuperIsland Battery Review.before-fault-latch-20261104T0943.app。

新后台记录40C028F3-9A2D-4FC5-ACE3-3842235D43EB被系统标为enabled/disallowed，登录项开关off。旧job仍引用B700323B-F758-4BAF-9687-0F58444A5AFF并EX_CONFIG，未启动新版helper。已请求用户批准；包保持不变。批准后需要核对新记录启动与kernel CDHash，不能只看汇总开关。

为防批准时应用重开触发航海70，本次准备偏好暂为limit85、自动放电/航海/过热保护关闭，主控off；原偏好快照仍在，实测结束或取消后必须恢复。当前85%、AC attached、未充电。一次脉冲尚未执行，剩余任务为系统批准、运行身份确认、一次79–85受限验证及偏好恢复。不能称电池需求全部验收。


## 2026-11-04 10:25：固定新版运行与用户手测证据

用户批准后，旧B700启动任务仍EX_CONFIG。用既有同版修复流程移除旧job，再仅补交register，新40C028F3记录保持允许，无换包或再次要求用户批准。新helper PID30331，protocol17、epoch2EFEB826-333C-4FC9-B480-57B221F3DCBF，kernel CDHash 75cc57b8b96064b6f4d361cce6ce7b518a7ab41d 与安装包一致。

主控原准备83%放电尚未提交，用户开始自行手测，将长期上限改80并启动放电至80。用户明确要求只读观察，之后主控没有操作界面或写入控制，未触发一次暂停脉冲。

- 10:12:32 新电池电流-2461mA，80%目标读回；接电且实际放电。
- 系统电量85→84→83→82→81，10:22:01到80。
- 10:22:04模式自动转automatic；完成回执targetReached，operation B9C0B4EF-3607-4C7A-B4FF-E22C0F7DA9C5。
- 10:23:03、10:24:01、10:25:02三个新电池发布均80%、电流0、ExternalConnected=true。无lastFailure、manualRetry=false、recoveryPending=false。

因此本次用户手测的“原生放电85→80、达到目标停止、自动模式保持”有真实遥测证据，未再次出现进程误拦截或旧心跳重放。此结论不替代充电中暂停、一次500ms切换、完整校准或LED物理验证。

当前用户仍在手测；未覆盖其80%新设定，测试隔离的自动放电/航海/过热保护仍关闭。待用户结束后再协调恢复原偏好，不能在用户手测时擅自恢复。证据：protocol17-preparation.jsonl、protocol17-manual-target80.jsonl、manual-target80-result.json、protocol17-identity.json。
