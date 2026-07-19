# SuperIsland 全 App 中文化 PRD-TR2

## 基本信息

- 子项目：SuperIsland
- 归属：全 App / 本地化 / 用户可见文案
- 任务类型：A 新需求
- 标注版本：20260607
- 需求来源：用户要求“整个 app 中文化”，在当前合体版基础上，把 SuperIsland 的用户可见英文界面统一改为中文。
- 关联基础：本需求基于 `feature/chinese-localization-combined`，该分支已包含 Teleprompter / Word Tracking 与全屏隐藏改动。

## 本次范围

本次中文化覆盖 SuperIsland 主 App 中用户会直接看到的英文文案，包括 onboarding、菜单、Settings、模块配置、模块空状态、权限提示、更新弹窗、Teleprompter、Shelf、Calendar、Weather、Battery、Notifications、System HUD、Extension 设置面板与内置扩展展示文案。

本次不翻译代码标识符、文件名、bundle id、UserDefaults key、API 字段、日志内部标签、第三方品牌名和开发者调试专用字符串。SuperIsland、Codex、Claude、WhatsApp、Linear、Last.fm、AI 等品牌或通用专名保留英文。

## 功能点 1：核心 App 用户界面中文化

### 1. 业务目的

让中文用户打开 SuperIsland 后，不需要理解英文就能完成主要使用流程。核心目标是降低首次使用、日常切换模块、查看状态和调整设置时的理解成本，让应用从“功能可用”变成“中文环境下自然可用”。该功能解决的是当前界面大量英文散落在菜单、按钮、空状态、设置项、权限说明和模块标题中的问题。

### 2. 使用者

使用者是以中文为主要操作语言的 SuperIsland 用户，包括初次安装用户、日常使用动态岛模块的用户、需要调整 Settings 的用户，以及只偶尔进入某个模块配置的轻量用户。不适用角色是直接阅读源码、调试日志、扩展开发脚本或 GitHub PR diff 的开发者场景，这些场景保留技术标识和英文日志更有利于维护。

### 3. 触发

触发页面覆盖用户可见的主 App 界面：onboarding 引导页、菜单栏菜单、全展开 island、compact/expanded 模块视图、Settings 页面、更新弹窗、权限状态提示和模块空状态。计划标注元素包括 `data-annotation-id="app-localization-onboarding"`、`data-annotation-id="app-localization-main-ui"`、`data-annotation-id="app-localization-settings-ui"`、`data-annotation-id="app-localization-module-ui"`、`data-annotation-id="app-localization-dialogs"`。用户启动应用、打开设置、切换模块、进入弹窗或看到空状态时，界面应呈现中文。

### 4. 流程

1. 用户首次启动 SuperIsland，onboarding 标题、说明、按钮和权限状态以中文展示。
2. 用户打开菜单栏菜单，菜单项以中文展示，品牌名 SuperIsland 保持英文。
3. 用户打开 Settings，左侧导航、分组标题、说明、按钮、权限状态和模块名称以中文展示。
4. 用户切换到任意 island 模块，模块标题、空状态、操作按钮、状态说明和工具提示以中文展示。
5. 用户看到更新弹窗、错误提示或权限提示时，提示信息以中文解释当前状态和下一步动作。
6. 用户使用 Extension 设置页时，通用管理文案中文化；第三方扩展名称、服务名称和必要的登录协议名保持原文。
7. 用户重新启动应用后，中文文案保持一致，不依赖运行时网络或额外配置。

### 5. 规则

- 只翻译用户可见文案，不改业务逻辑、状态流转、权限请求顺序、模块启用规则和手势逻辑。
- SuperIsland 品牌名保留英文，不翻译成“超级岛”。
- Codex、Claude、WhatsApp、Linear、Last.fm、AI、Node.js、Python 等品牌、产品名或技术名保留英文。
- UserDefaults key、notification name、bundle identifier、extension id、API 字段、文件路径、data-annotation-id 和日志内部机器可读字段不得翻译。
- 用户可见错误信息需要中文化，并尽量保留能帮助排查的技术名，例如 “Node.js 未安装” 可以保留 Node.js。
- 短按钮优先使用短中文，避免撑破现有 macOS 控件宽度。
- 同一概念在全 App 内必须使用同一中文词，例如 Settings 统一为“设置”，Notifications 统一为“通知”，Battery 统一为“电池”。
- 动态数值、日期、百分比、温度、倒计时和快捷键占位符必须保留原有变量插值，不得写死。
- 中文化不得改变菜单快捷键和系统按钮语义。
- 代码中已有英文注释和开发者日志可保留，除非该日志直接展示给用户。

### 6. 边界

- 空状态：没有通知、没有日程、没有 shelf 项目、没有 home 模块等空状态需要中文展示。
- 数量限制：包含数字的文案要保持数字动态展示，例如事件数量、保存天数、版本号和百分比。
- 重复：同一英文文案如果在多个文件出现，应统一中文译法，避免一处叫“提词器”、另一处叫“字幕”。
- 权限：麦克风、语音识别、辅助功能、日历、自动启动等权限说明必须中文化，但不改变系统权限触发逻辑。
- 网络异常：更新检查、扩展登录或外部服务失败时，错误提示中文化并保留必要服务名。
- 布局：长中文说明不能和按钮、图标、状态文字重叠；必要时使用更短译文或现有换行布局。
- 第三方内容：来自外部服务的原始标题、歌曲名、会议名、天气城市名和用户数据不翻译。

### 7. 数据

- 前端 state 字段：沿用现有 SwiftUI / AppKit 状态，不新增本地化状态字段。
- 持久化字段：不新增 UserDefaults key；已有设置项含义和存储值保持不变。
- 接口：不新增网络接口；不修改扩展通信协议字段。
- 资源：本阶段优先替换 Swift/JS 中现有用户可见字符串；如果后续需要正式多语言包，可再迁移到 `Localizable.strings`。

### 8. 验收

- [ ] 首次启动 onboarding 的标题、说明、按钮和权限状态为中文。
- [ ] 菜单栏菜单项为中文，SuperIsland 品牌名保留英文。
- [ ] Settings 页面主要导航、分组、说明、按钮、状态和模块名称为中文。
- [ ] 全展开 island 的模块标题、空状态、操作按钮和工具提示为中文。
- [ ] 更新弹窗、权限提示和用户可见错误提示为中文。
- [ ] 中文文案没有挤压、截断或重叠到影响使用。
- [ ] 中文化后应用行为与中文化前一致，尤其不影响 Teleprompter、手势切换和全屏隐藏。

## 功能点 2：Settings 与权限管理文案中文化

### 1. 业务目的

让用户在设置中能准确理解每个开关、权限、调试项和模块配置的作用，减少因为英文说明造成的误操作。该功能重点解决 Settings 页面信息密度高、英文说明多、权限状态和模块说明难以快速判断的问题。

### 2. 使用者

使用者是需要调整 SuperIsland 设置的中文用户，包括启用或关闭模块的人、排查权限问题的人、管理扩展登录的人和需要修改外观行为的人。不适用角色是扩展开发者查看原始 manifest、终端日志或调试接口字段的场景，这些信息允许保持英文技术名。

### 3. 触发

触发页面是 Settings 主窗口及其子页面，包括 General、Appearance、Modules、Extensions、Advanced 与各模块详情。计划标注元素包括 `data-annotation-id="app-localization-settings-ui"`、`data-annotation-id="app-localization-permission-ui"`、`data-annotation-id="app-localization-extension-ui"`。用户打开设置、进入模块详情、查看权限状态、管理扩展或点击检查更新时触发。

### 4. 流程

1. 用户打开 Settings，导航与标题以中文展示。
2. 用户进入 General，启动项、菜单栏图标、全屏隐藏、动画速度和交互权限说明以中文展示。
3. 用户进入 Appearance，尺寸、动画、重置和外观相关说明以中文展示。
4. 用户进入 Modules，模块分组、模块名称、模块说明、启用开关和详情按钮以中文展示。
5. 用户进入 Productivity / Teleprompter，提词器设置、语音跟读权限、编辑稿件入口和状态提示以中文展示。
6. 用户进入 Extensions，筛选器、详情、设置、日志、登录、断开连接等管理动作以中文展示。
7. 用户进入 Advanced，显示器、能耗诊断、调试、重置和关于信息以中文展示。

### 5. 规则

- Settings 中的英文分类名必须有稳定中文译法：General 为“通用”，Appearance 为“外观”，Modules 为“模块”，Extensions 为“扩展”，Advanced 为“高级”。
- 权限类按钮统一使用“授权”“打开设置”“已授权”“需要授权”等表达，避免同一状态多种叫法。
- 危险或不可逆操作文案要清楚，例如重置设置、退出登录、断开连接、清空记录等。
- Extension 的展示名称保留 manifest 或服务原名，管理动作中文化。
- Recent Logs 这类用户可见面板标题中文化，但日志内容本身可保持原始输出。
- 如果中文化后按钮过长，优先缩短译文，不改控件结构。
- 设置项说明要保留原本的信息密度，不为了变短删掉关键条件。

### 6. 边界

- 权限未决定、已授权、被拒绝、受限、未知状态都需要有中文状态或说明。
- 扩展登录中二维码、轮询、过期、刷新、断开连接等状态需要中文管理文案。
- 更新检查失败、版本不可用、网络错误需要中文提示，但保留版本号和错误原因。
- “Reset All Settings” 一类操作不得因为中文化削弱风险提示。
- 设置窗口窄宽度下，中文说明不得覆盖按钮或图标。
- 对已有系统权限弹窗文案无法控制的部分，不在 App 内伪造系统弹窗，只中文化应用自身说明。

### 7. 数据

- 前端 state 字段：沿用现有设置模型和权限状态枚举。
- 持久化字段：不修改现有设置存储值；中文只影响展示层。
- 接口：扩展配置 schema、登录协议和本地服务端口字段保持原样。
- 本地资源：中文化字符串落在现有 Swift/JS 源码中；后续多语言化再独立抽取。

### 8. 验收

- [ ] Settings 五个主分区名称和页面标题为中文。
- [ ] General、Appearance、Modules、Extensions、Advanced 的主要设置项和说明为中文。
- [ ] 权限状态和授权动作有清晰中文提示。
- [ ] 扩展设置管理动作中文化，扩展名称和服务品牌保留原文。
- [ ] 危险操作仍能明确表达风险和后果。
- [ ] 中文化不改变任何设置项的保存值或开关行为。

## 功能点 3：模块视图与 Teleprompter 术语统一中文化

### 1. 业务目的

让 island 内各模块在中文环境下读起来一致，特别是已经融合的 Teleprompter / Word Tracking 功能，避免用户看到“Teleprompter、Classic、Word Tracking、Script”等混杂术语而难以判断功能差异。该功能解决模块视图、编辑窗口、状态栏和按钮之间中文术语不一致的问题。

### 2. 使用者

使用者是通过 island 查看模块内容、切换模块或使用提词器的中文用户。重点使用者包括用提词器录课、直播、演讲、视频拍摄的用户，以及日常查看天气、日历、电池、通知、媒体和 Shelf 的用户。不适用角色是必须对照原始 Textream / SuperIsland 代码命名进行开发的维护者。

### 3. 触发

触发页面包括 compact island、expanded island、full expanded island、Teleprompter 稿件编辑窗口以及各模块详情。计划标注元素包括 `data-annotation-id="app-localization-module-ui"`、`data-annotation-id="app-localization-teleprompter-ui"`、`data-annotation-id="app-localization-empty-states"`。用户切换模块、编辑稿件、开始提词器、查看空状态或查看模块内操作按钮时触发。

### 4. 流程

1. 用户打开 island 模块，模块标题和空状态用中文展示。
2. 用户切到 Teleprompter，模块名显示为“提词器”。
3. 用户打开稿件编辑窗口，标题、按钮、字号、对齐、速度、语言和模式选择为中文。
4. 用户选择模式，“Classic” 显示为“匀速滚动”，“Word Tracking” 显示为“语音跟读”。
5. 用户开始播放，状态栏和错误提示用中文说明正在听音、权限缺失、未匹配或已暂停。
6. 用户查看 Weather、Calendar、Battery、Notifications、Shelf、System HUD 等模块，常见状态和动作中文化。
7. 用户切换回设置页，同一模块在设置和 island 中使用一致中文名。

### 5. 规则

- Teleprompter 在用户界面统一译为“提词器”。
- Script 在提词器语境下统一译为“稿件”或“口播稿”，按钮优先用“编辑稿件”。
- Classic 在模式选择中译为“匀速滚动”。
- Word Tracking 在模式选择中译为“语音跟读”。
- Speech Recognition 在权限或说明中译为“语音识别”。
- Listening、Heard、Matched、Ready、No script、Add script 等提词器状态必须中文化。
- 中文化只改展示文案，不改变语音识别 locale、匹配算法、分词策略、行锚定滚动和高亮推进逻辑。
- Weather、Calendar、Battery、Notifications、Shelf 等模块名称使用自然中文，但第三方数据内容不翻译。
- 图标按钮如果只有 tooltip/help label，则 tooltip 中文化；图标本身保持。

### 6. 边界

- 提词器识别准确性：中文化不得修改识别 hint、locale id、匹配阈值或文本归一化逻辑，除非该修改明确属于识别 bug 修复。
- 高亮跳动：中文化不得改动 Word Tracking 的进度推进、行锚定和滚动规则。
- 格式保留：中文化不得影响稿件换行、空行、对齐和字号设置。
- 长状态文本：提词器底部状态区域空间有限，中文状态必须短而清楚。
- 混合语言稿件：用户稿件本身保持原文，不被自动翻译。
- 模块空状态：没有数据时用中文说明；有用户数据时只翻译 UI 标签，不改用户内容。

### 7. 数据

- 前端 state 字段：沿用现有 `TeleprompterState`、模块状态、权限状态和扩展状态。
- 持久化字段：提词器模式、语言、速度、字号、对齐和稿件内容保存逻辑不变。
- 接口：语音识别、日历、天气、媒体、通知和扩展接口不变。
- 展示映射：新增或调整的只是英文 UI 文案到中文文案的展示映射。

### 8. 验收

- [ ] Teleprompter 在用户界面统一显示为“提词器”。
- [ ] Classic 显示为“匀速滚动”，Word Tracking 显示为“语音跟读”。
- [ ] 稿件编辑窗口的标题、按钮、控制项和说明为中文。
- [ ] 语音跟读状态提示为中文，且不影响识别准确性、高亮推进和行锚定滚动。
- [ ] Weather、Calendar、Battery、Notifications、Shelf、System HUD 等模块常见标题、按钮和空状态为中文。
- [ ] 用户输入内容、第三方内容和品牌名保持原样。

## 功能点 4：中文化打包与回归验证

### 1. 业务目的

确保中文化不是只停留在源码修改，而是能形成用户可安装、可运行、包含 Teleprompter 与全屏隐藏能力的最新版安装包。该功能解决“改完代码但用户启动的仍是旧版本”“安装包缺少某个分支功能”“权限或签名异常导致无法使用”的交付风险。

### 2. 使用者

使用者是需要在本机或另一台 Mac 安装合体版 SuperIsland 的用户，以及后续要把该版本继续提交到自己仓库分支的维护者。不适用角色是只看源码、不安装运行的开发者审查场景。

### 3. 触发

触发动作是中文化代码完成后执行构建、打包、安装或分发。计划标注元素为 `data-annotation-id="app-localization-package"`。用户要求“重新打包”“放桌面”“给另一台电脑装”或需要验证当前运行版本时触发。

### 4. 流程

1. 中文化代码完成后，确认当前分支仍包含 Teleprompter 与 fullscreen hide 两组提交。
2. 执行 Xcode 构建或项目既有构建命令。
3. 检查构建产物是否包含最新版 app 名称、bundle id 和必要 entitlements。
4. 生成可安装压缩包或 dmg，并放到用户指定位置。
5. 清理或提示旧安装包和旧 app 的风险，避免 Spotlight 或权限列表中出现多个 SuperIsland 干扰判断。
6. 用户安装后启动应用，验证中文界面、提词器、全屏隐藏和权限提示。

### 5. 规则

- 打包必须基于当前合体分支，不能只包含 full screen 或只包含 Teleprompter。
- 打包前必须检查 git branch 与最近提交，避免从旧分支构建。
- 打包文件名应能表达日期或功能组合，便于用户区分版本。
- 打包不应删除用户正在使用的 app，除非用户明确要求清理。
- 安装包用于本机或另一台电脑测试时，需要保留必要权限说明，避免误判为功能失效。
- 中文化不得修改签名、权限 entitlement、bundle id 和隐私说明，除非构建必须。

### 6. 边界

- 另一台电脑首次安装时，需要重新授权麦克风、语音识别、辅助功能等系统权限。
- 如果机器上存在多个 SuperIsland app，Spotlight 和系统权限列表可能显示旧包名或旧构建，需要明确清理或选择正确 app。
- 如果构建失败，需要先判断是签名、依赖、Xcode scheme 还是沙盒权限问题，再给出下一步。
- 如果只做源码中文化但未打包，用户本机正在运行的 app 不会自动更新。
- 如果 macOS 缓存旧权限项，可能需要退出 app、替换 app、重新启动或在系统设置中确认权限对象。

### 7. 数据

- 构建输入：当前 Git 分支源码、Xcode project/scheme、Info.plist、entitlements。
- 构建输出：`.app` 和用户指定的安装包文件。
- 持久化数据：不迁移用户设置，不清空已有 Teleprompter 稿件和模块配置。
- 接口：不新增接口；只验证安装产物与运行权限。

### 8. 验收

- [ ] 构建前确认当前分支包含 Teleprompter 与 full screen hide 两组功能。
- [ ] 构建成功并生成可安装产物。
- [ ] 安装后 App 用户可见界面为中文。
- [ ] 安装后 Teleprompter / 语音跟读仍可使用。
- [ ] 安装后浏览器或播放器全屏时隐藏逻辑仍可使用。
- [ ] 用户能明确区分新安装包与旧安装包，避免启动错版本。

## 术语表

- SuperIsland：保留英文
- Settings：设置
- General：通用
- Appearance：外观
- Modules：模块
- Extensions：扩展
- Advanced：高级
- Teleprompter：提词器
- Script：稿件 / 口播稿
- Edit Script：编辑稿件
- Classic：匀速滚动
- Word Tracking：语音跟读
- Speech Recognition：语音识别
- Notifications：通知
- Battery：电池
- Calendar：日历
- Weather：天气
- Shelf：暂存架
- Now Playing：正在播放
- Home：首页
- Fullscreen：全屏

## 附录：计划标注 ID

- `app-localization-onboarding`：首次启动 onboarding 引导文案
- `app-localization-main-ui`：菜单栏、主 island、全展开基础界面文案
- `app-localization-settings-ui`：Settings 主窗口与设置项文案
- `app-localization-permission-ui`：权限状态、授权按钮、系统设置引导文案
- `app-localization-extension-ui`：扩展管理、登录、日志、断开连接等文案
- `app-localization-module-ui`：模块标题、空状态、操作按钮和工具提示
- `app-localization-teleprompter-ui`：提词器、稿件编辑、模式选择、语音跟读状态文案
- `app-localization-dialogs`：更新弹窗、错误弹窗、确认弹窗文案
- `app-localization-empty-states`：无通知、无日程、无项目、无模块等空状态
- `app-localization-package`：构建打包与安装验证
