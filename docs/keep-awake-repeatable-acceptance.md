# SuperIsland 可重复合盖验收

目标是分别证明：任务运行时保持、真实终结后自然释放、首次实际睡眠、合盖非人工唤醒后 App 再请求并实际睡眠。任何一项不能代替另一项。开盖不请求睡眠；其他任务和外部断言保持不动。

## 当前证据

2026-11-02 安装版本 20261102143113 / PID 34913，helper 85974。本轮仅新增只读验收器、反例测试和独立测试聊天，没有修改生产电源逻辑或重新安装。

- 16:01—16:13 真实物理周期：保持、最后任务终结约 32 秒后释放、约 70.93 秒内核睡眠已证实；只有开盖唤醒，后台醒后再睡未覆盖。
- 新独立父子样本：App 接收了父子各自的真实运行和精确完成事件，两条 pending 均移除。生产元数据 reader 解析出 2 个成员、1 个根、1 条父子归属；真实事件通过未修改的生产归并投影回放，子结束后父仍运行。全体轮次结束后整体会话状态仍未知，没有据此宣告长聊天结束。此证据不是原生面板点击验收。

证据在 `build/RepeatableLidAcceptance.noindex/`；已安装旧周期在 `build/WakeHierarchyRepair.noindex/Installation-20261102-142948/Readback-20261102-1613/`。不改写旧结果。

## 下一轮的必要条件

计时任务必须最后启动：先完成管理员认证、独立记录窗口、预约及回滚读回、界面定位和审查记录。新900秒窗口的受控wake可设在窗口开始约600秒处，至少留下180秒尾段；发送前核对首次睡眠与维护宽限都放得下。发送后只做一次原生运行/保持核对，并在20秒内结束回复交接合盖，不在这时写长报告、调试输入或变更预约。若无法及时交接或合盖余量不足，撤回就绪结论，不能把提示时间当实际合盖。未实际观察合盖的周期必须记为未验收。

1. 等其他已监测执行自然终结；未知、Stop、失联或空清单不作为完成。不催停现有任务。
2. 当场重新核对相同安装身份、PID、开盖、AC、外屏 0、无 AlDente 冲突、无热/低电保护；停止会自行制造任务的跟进。
3. 新建独立有限物理阶段；App 原生记录请求最长 900 秒、每段 2 MiB，私有目录 0700/文件 0600。保留历史和真实段间隙，不建立外部持续采样进程。
4. 如需新的跨合盖任务，由用户在 ZCode 独立会话执行前台 `sleep 240`，不读写文件、不后台运行。看到真实运行及稳定实际保持后才叫合盖，覆盖至少 120 秒。
5. 若用户另行允许一次受控唤醒，保存当前系统预约，生成未来窗口内一条独立 owner 的绝对时间 `wake`；仅在管理员认证后安排，并读回时间、类型、owner。任务未按预期结束、条件变化或窗口不足时精确取消自有预约并保存取消读回，不强制终结任务、不强制睡眠。
6. 合盖等待真实任务结束、约 30 秒释放、首次睡眠，再观察该预约是否实际唤醒和后续再睡。录制截止后再由用户开盖读回；不要用聊天轮询制造唤醒。

## 一次性唤醒的权限和边界

`prepare-wake` 只打印待审阅 JSON，不调用命令、不创建预约。实际安排需单独用户授权及管理员认证。过期示例不可执行；准备实际物理窗口时重新生成并检查。

生成的 `schedule` 使用绝对时间和唯一 `com.workview.SuperIsland.Acceptance.UUID` owner；`exactRollback` 必须保留完全一致的类型、时间和 owner。不使用 `relative`、`cancelall`，不改系统的其他预约、网络、蓝牙、电源设置或 helper 权限。

公开 `wake` 接口不保证产生 DarkWake。按真实系统日志分类为 Wake 或 DarkWake；若只有普通 Wake，只能说明合盖普通唤醒路径，不能声称 DarkWake 专门路径已覆盖。若系统先自行睡回去，单独记录，不算 App 再次请求路径通过。

Apple 来源：[pmset 手册](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmset/pmset.1)、[公开 IOPMLib 接口](https://github.com/apple-oss-distributions/IOKitUser/blob/main/pwr_mgt.subproj/IOPMLib.h)。

## 只读验收器

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -p test_verify_keep_awake_cycle.py -v
python3 scripts/verify-keep-awake-cycle.py analyze --native NATIVE.json --system SYSTEM.json --recap RECAP.json --pid PID --build BUILD
python3 scripts/verify-keep-awake-cycle.py prepare-wake --now EPOCH --start EPOCH --wake EPOCH --end EPOCH
```

输入每个最多 2 MiB。native 是同 PID/build 的匿名窗口：`pid,build,start,firstOpen.epoch,rows`，rows 仅含事件、状态、匿名任务身份、功耗和时钟；system 是 `lines` 中的系统电源事件行；recap 是对应周期的匿名释放原因、时钟和边界。正文、工具内容、凭据、原始会话 ID、标题不进入证据。

验收器拒绝：未来唤醒预约当成实际唤醒、API 受理当成睡眠、单凭睡眠日志缺内核/双时钟证据、不匹配 PID/build、任务清单截断、终态身份不匹配、旧 recap、过早再请求、跨唤醒周期错归因、CPU 未释放却请求、开盖或外屏存在。后续新任务不能倒改此前已证明的释放区间。

只有同一物理阶段完整关联的实际唤醒、闭盖/任务守卫、维护宽限、App 再请求、系统自身 PID 对应的 Software Sleep 和真实再次睡眠证据齐全，`backgroundRetry` 才通过。CPU 断言阻止时记录安全暂缓，不能为通过验收而取消其他应用断言。
