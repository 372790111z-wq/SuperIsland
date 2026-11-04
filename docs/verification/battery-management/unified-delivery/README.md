# 统一主线交付（2026-11-04）

用户授权：提交电池工作、合并最新主线，更新本机 `/Applications/SuperIsland.app`，以单一应用测试；不推送远端。

## 来源与边界

- 主线 `41645f3` 保留保持唤醒、主聊天归并及截图修复；电池检查点 `7cd9424`。
- 本机主程序保持 `com.workview.SuperIsland.WE1Debug` 和已有签名身份；不覆盖成 BM1 的偏好域。
- 独立 Battery Review 的 85→80 目标放电及到点自动结束有实机证据，不能当成统一包已通过。
- 500 ms CHIE 切换尚未执行，也未开放到普通包；完整 100%/10% 校准不在本轮授权范围。

## 本次修正

- 接通 WE1 电池 helper 身份、启动失败识别、关联应用声明及独立嵌套签名。
- 进程隔离在路径与生命周期快照不同步时最多重采样三次；持续未知仍拦截，保留具体 syscall、尺寸、状态及出生时间。全次隔离检查有一秒预算。
- 状态与失败文字由可选择的 AppKit 文本控件直接提供辅助功能标签和值，避开故障栈中的 SwiftUI 标签解析。10:30 崩溃确定为 AX 标签递归，但不能从既有堆栈认定具体控件；最小旧控件探针未复现。
- 合并需求归档为 20261104，采用 20261102 主线内容及 BM1，历史归档保留，两个 PRD 全文已逐字校验。

## 对抗式复核

- 未放宽未知存活进程；路径重新出现后仍检查是否是旧 helper/worker。
- 没有改变旧请求跨重启限制、故障确认、恢复日志及一次试验票据。
- 构建须来自提交后干净 checkout；安装前保留旧包和偏好，确认旧后台无待恢复责任。
- 新 helper 的注册/系统允许、真实运行二进制和实际充放电结果须分别核验。已有单元测试不能代替设备验收。

构建、打包及安装证据保存在本次 checkout 的 `build/unified-delivery/`。当前仍在验证，完成结果另行记录。

## 后台标识迁移修正

用户批准后，旧 label 的 launchd `Executable` 仍指向退役的 Review，`EX_CONFIG 78`；先前登记表的 parent version 不能证明运行文件已切换。统一 WE1 宿主改用 `com.workview.SuperIsland.WE1Debug.BatteryControl`，其独立 plist 仅关联 WE1；生产与 Review 保持旧入口。客户端注册前只注销旧服务，后续批准重试不会因此注销新服务。

代码签名标识继续为 `com.workview.SuperIsland.BatteryManagementHelper`。恢复目录、manual-retry、control.lock、独立 Review journal 和 root worker cache 均保持原路径。不能用改服务标识跳过恢复状态；两个版本仍受同一控制锁约束。迁移代码测试包括宿主/辅助程序路由、两个 plist 的端点隔离、稳定存储/签名契约、旧服务注销失败阻断和批准重试。
