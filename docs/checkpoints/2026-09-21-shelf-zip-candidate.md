# 暂存架 ZIP 压缩安装与验证（2026-09-21）

## 当前状态

- 已安装并正常运行 `20260921144151`，源码 `8754b70efd9bfe0fdba3bdf42c8b1329649a532e`。只替换并重启 WE1，正常启动已去掉诊断环境变量。
- 用户报告的“ZIP 拖出改名”和“暂存区水平滚动误切模块”已在该安装包原生复测通过；这是自动化实机验证，尚未收到用户对 144151 的验收回复。
- 106 项相关测试、Release arm64 构建与严格签名检查通过。下文保留候选制作及中间失败过程，当前结果以文末 144151 记录为准。

## 范围与来源

- 用户确认交互稿后明确要求“直接开发，不写 PRD”。按此授权实施，不新增 PRD。
- 分支：`feat/we1-shelf-zip-20260921`，基线 `0ff673fe09b8821c821a8d0458bb0ddfe47a941a` / `we1-001213-saved-20260921`。
- 布局为 AirDrop、暂存架、右侧 ZIP 压缩区；原有文件共享和暂存继续复用现有接收方式。
- 最初候选阶段没有安装或操作鼠标；随后用户明确确认安装，并授权原生鼠标事件仅测试专用文件。本轮没有推送远端。

## 已实现

- 拖入本地文件或文件夹后自动分别生成 ZIP，源文件保留。原目录输出完整名称，例如 `报告.pdf.zip`，重名依次使用 `报告.pdf (1).zip`。
- 原生流式 Deflate，UTF-8 文件名，保留文件夹根目录和空目录；过滤 `.DS_Store`、`._*`、`__MACOSX`；拒绝符号链接与特殊文件。
- 自动支持 ZIP64。临时归档完成后重新解压校验 CRC 与大小，再原子发布；避免覆盖已有项目。取消、源文件变化和写入失败清理本次临时文件。
- 压缩结果加入暂存架，沿用现有拖出与共享。部分失败保留成功结果，仅重试失败项；选择新输出目录时应用于所有失败文件。
- 暂存架托管图片在开始整批压缩前选择可见输出目录，取消不生成任何 ZIP。内部拖动保留原项目及书签身份。
- ZIP 区拒绝纯文本和网络链接，不回落到父级普通暂存接收；忙碌时不创建重复任务。增加处理状态、取消、重试与更换位置操作。
- 暂存页扩宽以容纳新区域，窄屏缩小两侧区域；切换其他页恢复其原有宽度。窗口增强、Dock、Cmd-Tab、调度中心代码没有修改。

## 验证

- `build/WE1ShelfZIP.noindex/Tests2.xcresult`：84 项相关测试全部通过。包含 ZIP 引擎 18、协调器 8、接收加载器 4，以及既有拖放、输入隔离和窗口拖动门禁回归。
- 覆盖中文与特殊字符、完整名称、空文件/目录、重复编号、并发无覆盖、符号链接/FIFO、取消、源变化、输出目录替换、超时 provider、部分失败重试、托管图片取消及内部拖放。
- 使用独立 `/usr/bin/unzip`、`ditto`、Python `zipfile` 校验生成内容；生产代码只使用系统 zlib，不依赖 Python 或外部压缩进程。
- ZIP64 用降低阈值的小型数据触发各分支并独立解压，未实际生成大于 4 GB 或超过 65535 项的测试文件。
- Release arm64 构建通过：`build/WE1ShelfZIP.noindex/release.log`。Xcode 的 CoreDevice / iOS 模拟器环境警告不影响本次 macOS 构建与测试。
- `git diff --check` 通过。测试均使用专用临时文件，没有压缩或删除用户文件。

## 交付边界与回退

- 编译、单元/集成测试和 HTML 交互稿通过，不等同原生拖放验收；原生结果单列于下文。Windows 实际解压尚未验证，不宣称任意 macOS 文件名都兼容所有 Windows 解压器。
- 候选包与构建清单位于忽略目录 `build/WE1ShelfZIP.noindex/`；本轮确认安装后已完整保留 001213 与各次中间应用包，只替换 WE1，不清理偏好或用户数据。
- 原稳定安装版本 `20260921001213`，二进制 SHA-256 为 `0c051a95983b8a000cbbe0db050a782666d5ab269899c35f678b425863579adb`。其代码、安装与已知顶部拖动路径边界见同目录 `2026-09-21-shelf-native-receive.md`。
- 源码可从 `we1-001213-saved-20260921` 另建工作区恢复；不以重置或覆盖方式破坏当前工作区。

## 已生成候选包

- 源码提交：`b964e4a948351e1a426454131a801781371f58c2`。
- 构建：`20260921114718`，约 20.3 MB；路径 `build/WE1ShelfZIP.noindex/Candidate-20260921114718.noindex/SuperIsland-WE1-Debug.app`。
- 候选二进制 SHA-256：`7e5a969d37743c3a0dec8e38962213e98b3a3ddcd163a6d415095612181a7361`。
- 沿用 `SuperIsland WE1 Debug Local Code Signing`，签名要求与已安装 001213 一致，严格签名验证通过；无覆盖率代码、debug dylib 或测试包。
- 此候选原始清单已留存为 `build/WE1ShelfZIP.noindex/candidate-114718.json`；当时未安装、未原生实测。

## 安装实测发现与内部拖动修复

- 用户确认后安装了 114718，完整 001213 保留在 `build/WE1ShelfZIP.noindex/Rollback/SuperIsland-WE1-Debug-20260921001213.app`，哈希和签名核验通过。
- 114718 从 Finder 拖入文件、文件夹及重复编号通过；实际 ZIP 解压/CRC/UTF-8 检查通过，保留空目录并过滤元数据。暂存接收、AirDrop 面板出现后取消均通过；测试路径未观察到调度中心根节点或 Finder 窗口变形。
- 内部拖动仅“有输出”不够：回读结果发现 ZIP 被写到 `~/Library/Caches/com.apple.SwiftUI.Drag-…`。`NSItemProvider(contentsOf:)` 提供内容，SwiftUI 把它物化成缓存副本，原路径和自定义进程内身份未保留。证据在 `native-internal-failure-114718.json`。
- 修复：暂存项拖出统一提供原始 NSURL，避免内容副本；ZIP loader 在进程内身份缺失时，只用现有项当前解析 URL 精确匹配，保留托管图片名称与书签。不同目录同名文件不匹配，不用可能过期的存储路径替代已解析书签，不新增事件监听或拖动身份状态。
- 修复后相关测试增至 88 项，全通过（`Tests5.xcresult`），Release 构建通过（`release2.log`）。新增覆盖文件 URL 导出、URL-only 内部身份恢复、同名路径区分及旧路径被占用的书签边界。
- 此处记录代码与测试结果；修复后的安装包和原生复测结果追加在后续安装记录中。114718 不标记为完整验收通过。

后续 141333 实测证明，只改 NSURL provider 仍不足：SwiftUI 的原生拖板保留了自定义 item UUID，但文件 URL 仍指向 Drag 缓存。因此补充把该自定义类型加入接收表示列表，并接受其 NSString / Data 两种桥接结果；导出 provider 明确提供原文件名 `suggestedName`。未以 UI 显示“已压缩”代替实际输出位置核验。

同轮用户报告暂存架水平滚动误切整个模块。已将父滚轮识别限定为：暂存架中的子 NSScrollView 拥有整个滚动手势，包括边界、不溢出、离开区域和惯性；保留原滚轮事件。其他模块、切页按钮和 `cycleModule` 没有禁用。两项修复共 101 项相关测试通过（`Tests6.xcresult`），Release 构建通过（`release3.log`），等待最终安装实测回读。

## 144151 最终安装实测

- 143051 诊断直接证明：原生 `.drag` 有自定义 UUID，但 SwiftUI 的 `DropInfo` 只传一个 file-url provider（`local=0, types=1`）。仅改变 Data / NSString 解码无法解决该边界。
- 最小修复是在 ZIP `performDrop` 同步捕获本次原生拖放板的单项 UUID，仅对单 provider 使用；异步时从仍存在的 Shelf 项恢复原 URL / 书签。找不到原项即报告不可用，不借用缓存副本，不按同名文件猜测，不增加全局鼠标监听。普通外部拖放没有该 UUID，继续走原 file-url 加载。
- `Tests8.xcresult`：106 项、0 失败；新增覆盖 file-only SwiftUI provider、后续外部拖放、多个 pasteboard item、多 provider、原项移除及异步前身份快照。`release5.log`：构建通过。
- `native-internal-144151-2.jsonl`：暂存架源文件拖到 ZIP 区后，ZIP 位于原目录；原文件仍暂存。实际 ZIP 独立解压与 CRC 检查通过。
- `native-export-144151-verification.json`：该 ZIP 拖回专用 Finder 文件夹后仍名为 `WE1-原路径验证.txt.zip`，与原 ZIP 字节完全相同，原 ZIP 保留。导出 SHA-256：`939ea668ad392300c882dd479ecd0fa9fca92fdc558b71383ab7f58f4440d796`。
- `native-scroll-144151.jsonl`：文件区域内连续左右精确滚动均保持暂存页；区域外同样事件能够切换模块，随后恢复暂存页。结合 12 项滚动归属测试覆盖边界、少量内容、移出及惯性。
- `native-sequence-144151-verification.json`：内部 A 之后两次外部 B 拖入均产生 B 的正确归档与重名编号，CRC / 解压内容一致；没有继承 A 身份。测试中合成 Esc 未成功取消一次内部拖动，实际生成了 A 的编号归档，因此该次不计作“按 Esc 取消拖动”通过，也没有用它证明取消行为。
- `native-share-144151.jsonl` 与原生 UI：Finder 测试文件拖入 AirDrop 后系统面板正常出现，已点击取消，没有向任何设备发送。原生外部拖放采样未观察到调度中心根节点或 Finder 窗口变形。
- 测试结束仅通过暂存项“移除”清理 5 项本轮测试引用，回读 Shelf 为 0，与本次最终安装后的测试起点一致；不删除磁盘源文件。两个测试 Finder 窗口已关闭，鼠标按键已释放，WE1 正常模式运行。

## 安装来源与回退

- 安装路径：`/Applications/SuperIsland-WE1-Debug.app`；当前二进制 SHA-256：`3431f5d3f6749ffb79abac94eec8f9118c9fe27439c1cd8835a0f5dbcfbda28e`。
- 沿用原本本地签名身份，指定要求保持 `identifier "com.workview.SuperIsland.WE1Debug" and certificate root = H"5ba2336137a6ff57316e24449c3914b56e3ac4c9"`。严格签名检查通过，无新增权限提示。
- `candidate.json` / `installation.json` 为最终 144151 清单；此前清单均按版本号另存。
- 最初 001213 与 114718、141333、142411、143051 全包分别保存在 `build/WE1ShelfZIP.noindex/Rollback/`，未覆盖。需要回退时正常退出 WE1，使用对应签名完整包恢复；不重置仓库或删除用户偏好。
- 仍未验证：Windows 实际解压、大于 4 GB / 超过 65535 项实物归档、AirDrop 接收端传输、图片 / 文件夹拖向只接受内容 UTI 的其他第三方目标。本轮不把这些宣称为已通过。
