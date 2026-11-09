# MP1 本机安装记录 · 2026-11-09

用户明确授权“替换吧”。已将 `/Applications/SuperIsland.app` 从 `20261109110823` 替换为 **20261109145058**，启动并确认运行。源码提交 `e2719fea789e0008e9a5583d5f0ceafa98e284ea`；只在本地功能分支提交，未推送 GitHub、未发布远端包。

## 构建与校验

Release arm64 优化构建成功，构建前后源码 revision/tree 和干净状态一致。复用现有锁定依赖及已验证 WhatsApp bundle，没有升级依赖。构建回执：`build/MP1Release.noindex/build-receipt.json`。

保留 `com.workview.SuperIsland.WE1Debug` 和原指定签名要求；嵌套 helper 签名及 ZIP 解包验证通过。保留原窄 `BATTERY_PAUSE_REFRESH` 编译选项和包标记，调度中心诊断保持关闭。

二进制 SHA-256：`2cd8d4b80c26e62d647ca37e1e1d62c4f48553aabf2e1e1fb753a490e1c28080`。安装后再次核对哈希与严格签名，均一致。

## 安装、设置与回滚

旧进程 31808 正常退出，新进程 88236 从 `/Applications/SuperIsland.app/Contents/MacOS/SuperIsland` 运行。选定音乐开关、悬停/收起延迟、首页模块设置对比一致，没有删除用户数据。

旧版备份：[SuperIsland 20261109110823](</Users/muyz/Projects/new super island/worktrees/music-hover-half-expanded-20261109/build/MP1Release.noindex/Installation/Backup/SuperIsland.app>)。另保留移走的原目录：`/Users/muyz/Projects/new super island/worktrees/music-hover-half-expanded-20261109/build/MP1Release.noindex/Installation/Retired/SuperIsland.app`。如需恢复，可退出新版后将备份恢复到原安装路径；本次没有触发回滚。

包、manifest 和安装回执保留于 `build/MP1Release.noindex/`，不上传。

## 运行观察及验收边界

原生设置 UI 显示辅助功能、屏幕录制均“已生效”，调度中心 Pro 开关仍开启。新进程、安装版本、路径、签名和相关设置均已核验。

先前 43 项测试与 QQ 实际适配器操作证据见 [实施记录](MP1-implementation-validation.md)。本次安装后没有再修改 QQ 收藏或播放模式。安装后的真实悬停、全展开、上下曲/暂停/seek、多屏及其他模块完整回归仍待用户确认；启动成功不等同整体验收。
