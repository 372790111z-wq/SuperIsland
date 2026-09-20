# WE1 优化构建 160408 安装记录

- 安装时间：2026-09-20
- 用户授权：安装优化版本供查看，并删除旧应用；删除采用移到废纸篓。
- 实施范围：先安装体积优化版。扩展／高级开放仍为待确认 HTML，本轮没有实现或宣称开放这些功能。
- 源码提交：`b3c751b6abb5681657b25cad4c984decb79d6df1`；相对已安装102559含此前已确认的反馈文案改动。
- 实际路径：`/Applications/SuperIsland-WE1-Debug.app`
- 版本／构建：1.0.9 / **20260920160408**，显示名称 SuperIsland WE1。
- Bundle ID：`com.workview.SuperIsland.WE1Debug`，保持既有隔离行为和偏好域。

## 优化与签名

新建独立 `.noindex` DerivedData，使用 Release `-O`/wholemodule，关闭 Debug dylib、测试性和覆盖率。Xcode 的 `-enableCodeCoverage NO` 仅支持 testing，因此 build 使用实际 `ENABLE_CODE_COVERAGE=NO` 等选项；真实 Swift 命令无覆盖率参数，Mach-O无对应覆盖率段。只对暂存 App 主程序执行 `strip -D`，未使用会破坏 SwiftPM object 的全局strip配置。

签名后的完整安装包逻辑体积 **14,388,718字节（14.39 MB）**，较旧WE1的46,148,131字节减少68.82%；这是应用包字节，不能直接对应清理软件的卸载明细口径。未删减内置资源。

沿用本地证书 `SuperIsland WE1 Debug Local Code Signing`，新旧 designated requirement 完全相同，签名flags为0、无hardened runtime。正式版 `superisland://` URL scheme已从候选移除。

- 安装主程序 SHA256：`1509e3ce70fe0aafcc60d2955b51cbafb56759d316ab086472d00cb085e5306d`
- 原始构建主程序 SHA256：`ee813a1337e846d2266dd3a5da77b782d0b653ce639510d381984a1aff1c502a`
- 新旧证书需求：identifier WE1Debug + root certificate `5ba2336137a6ff57316e24449c3914b56e3ac4c9`。

## 实际验证

旧WE1进程正常退出，暂存旧安装包后替换同一路径；安装副本与候选hash一致，`codesign --verify --deep --strict`通过。从该安装路径启动新版，读取原生设置界面确认构建20260920160408。

原生窗口增强页显示辅助功能和屏幕录制均“已生效”；快捷删除⌘S、隐藏/显示⌘D、显示器移动等现有快捷键和开关仍在。验证时只有一个SuperIsland进程，路径为当前安装包，PID10794。设置窗口已留在窗口增强页供用户查看。

这是安装、启动、权限显示和配置保留验证；没有执行全面窗口动作回归，没有把用户实机验收标成完成。

## 旧版清理与恢复

应用程序目录只保留当前WE1。两份旧包通过FileManager.trashItem移入废纸篓，未清空废纸篓：

- 旧WE1 102559：`~/.Trash/SuperIsland-WE1-Debug-102559.app`
- 旧原版1.0.9/10：`~/.Trash/SuperIsland.app`

必要时先正常退出新版，再从上述位置恢复旧包；恢复旧WE1时应使用原 `/Applications/SuperIsland-WE1-Debug.app` 路径。偏好、数据、钥匙串、源码、Git、项目构建备份及验收归档未删除。

Xcode对raw构建的自动Launch Services登记已精确撤销；旧原版原路径及废纸篓旧包的登记亦按精确路径注销，未重置系统登记库。最终核验见下方`final-registration.json`。

## 本机证据

全部在忽略目录 `build/WE1OptimizedInstall.noindex/`：

- `command-build-only.json`、`build-build-only.log`、`raw-build-verification.json`：无覆盖率构建及源码输入哈希。
- `candidate.json`、`prepare_install.py`：签名候选及可复核包装流程。
- `install-operation.json`、`installed-verification.json`：安装路径/hash/实际进程和原生界面观察。
- `old-apps-trash.json`：两份旧包实际废纸篓恢复位置。
- `final-registration.json`：新安装路径保留、旧安装路径和废纸篓旧包登记已移除。

没有推送远端或发布发行包。
