# RISC-V 五子棋 + RT-Thread 任务书 v3（2026-10-14 立）

> 接 **v2**（`doc/reports/2026-10-13_taskbook_gomoku_v2.md`）。**本文写"v2 之后的变化 + 你的任务表"**；
> T2~T5 的详细设计与验收仍在 v2 §4，**别丢 v2**。
>
> 一句话：**T1' 的两件收尾基本清了（显示侧已由用户在板上确认）；"Cache 禁开"这条解除**
> （Cache 在 RT-Thread 上的挂死已定位修复、上板跑通）；你的主线**没变**：
> **T2 菜单 → T3 HUD → T4 AI 卡顿(G1/G2) → T5 CoreMark 编进固件**。

---

## 0. 三十秒版

1. **[OK] T1' §2.2 收尾完成**：用户 2026-10-14 **接 HDMI 显示器真按键下完一局并判出 `WHITE wins`**
   （日志 `doc/board/uart_20261014_141147.txt`，413 行）⇒ **显示侧不再是空白页**。
   "AI 思考期间画面不卡"**没有逐帧量化**，但有一条旁证：HARD 档 AI 算了 **5.7 s**（`nodes=10592 depth=6 t=5737ms`）
   期间 `[hb]` 照常打、之后按键照常有响应 ⇒ **至少没把 CPU 憋死**。
2. **[OK] "Cache 禁开"解除**：两条根因（约定 56/57）已修 + 上板验证（位流 `90944754`、
   `RTL=0x20261019`）。**但交付/跑分继续用 Cache 全关**（那是性能账，不是功能问题）。
3. **[!] T1' §2.1 `vblank timeout` 的定性已查清（2026-10-14）**：
   **不是"显示坏了"**（用户已接屏下棋正常），而是 **"vblank 等待变成了一次概率事件"** ——
   你在 `video_vblank_yield()` 里 `rt_thread_mdelay(1)` ⇒ 采样周期 ≈1 ms，
   而 `rtl/video/video_core.v:139` 的状态位是 **62.7 µs** 的 vsync 脉冲
   ⇒ 命中率量级 **6~12%**，等不到的调用由 **50 ms 超时**兜底（告警只打一次）。
   **三种处理**（兜底降级日志 / 换成 1.04 ms 消隐窗 / **加只读帧计数器，推荐**）见
   `doc/board/README.md` 的 rev1019 那节表格。**`rtl/video/**` 属视频线（要申请）**，
   所以：**先把日志降级 + 文档写清（你线内可做），RTL 方案与视频线一起排。**
4. **新增一条属于你的小修（可选、低风险）**：`CPU_HZ` 写死 85,005,100（见 §4.1）。
5. **你的负载是硬件 bug 的照妖镜** —— 这个 bug 只有"RT-Thread 五子棋 + 定时器中断"能抓到
   （CoreMark/riscv-tests 全盖不住）。所以**你也要跑 RT-Thread 四配置回归**（见 §4.2）。

---

## 1. 当前口径（别用旧数字）

| 项 | 值 |
|---|---|
| 位流（RT-Thread + I+D Cache）| **推荐烧 `bitstreams/rtthread_..._idcache_76mhz_rev1019_53b81dfe.sbit`**（横幅自洽 @76.5052MHz）；`90944754` 是同一 RTL 的上一颗（**已上板验证**，但横幅写死打 85.0051）。两者 `RTL=0x20261019` |
| 位流（生产/交付，Cache 全关）| `8894cdcb`（rtthread 五子棋 @85.0051）/ `bcd8fdd2`（CoreMark 365.93）|
| 板上时钟 | **85.0051 MHz**（生产档 `RATIO0=13.5`）/ **76.5052 MHz**（带 Cache 的降频档 `RATIO0=15.0`）|
| 固件镜像 | rtthread 版 = `10138 字`（`mem.hex` 20276 行）；**2026-10-14 变过**（横幅主频改成算出来的）|
| 仿真口径 | `-Sim` = 100 MHz + 短延时 + `HB_DELAY_MS=20`；上板口径 = 不带 `-Sim`（两者 `.text` 差几字节，别混）|

---

## 2. v2 之后发生了什么（你该知道的）

1. **Cache 挂死修完了**（本来挂在 CPU 线的 P0 上）：两条根因都在 `core.v` 的**冻结拍门控**上 ——
   ① ID/EX 清零漏 `mem_ready_int`（jal 链接值丢失）；② **CSR 写漏 `mem_ready_int`** ⇒ RT-Thread 的
   **`csrrw sp, mscratch, sp`** 在冻结拍把 **sp 读成写后值** ⇒ 中断处理函数跑在**线程栈**上 ⇒
   踩坏内核链表。证据：处理函数 C 帧落点 无 Cache `0xffec`(中断栈) / 修前 `0xb490`(线程栈) / 修后 `0xffec`。
   全文 `doc/reports/2026-10-14_cache_fix_bug2.md`。**对你的意义**：Cache 不再是禁区，
   但**默认仍是关**；RT-Thread 线现在**可以**开 Cache 跑（跑分/演示都别开，见 §3）。
2. **`RT-Thread` 仿真开关补齐了**（约定 55）：`scripts\rtthread\run_sim.ps1` 现在支持
   `-DCache / -ICache / -EarlyLd / -RxTrace / -PcTrace / -ITrace / -TrapTrace / -LTrace / -LdChk`，
   **默认一个都不带**（= 无 Cache）。**改任何东西后请显式带开关跑**（§4.2）。
3. **横幅主频不再写死**：`app/main.c` 原来把 `@85.0051MHz` 写成字符串字面量 ⇒ 76.5 档的位流也打 85.0051
   （看着像烧错位流）。已改成从 `BOARD_SYSTEM_CLOCK_HZ` 算（约定 58）。
   **判位流永远看 `RTL=` 那行（读 `mimpid`），不是横幅。**

---

## 3. 你的任务表（v3）

| # | 任务 | 优先级 | 一句话 |
|---|---|---|---|
| **T1'a** | **vblank 噪声兜底**（**指派给你**）：把 `[!] vblank timeout` 降成 `[i]`（或"连续 N 次失败才打"）+ 按 §0.3 的机制写进注释 | **P1（小改）** | 你线内可做（`scripts/gomoku/video_port.c`）；**根治方案（只读帧计数器）在 `rtl/video/*` = 视频线，要先申请** |
| **T1'b** | §2.2 若要答辩引用"思考期间画面不卡"，补一次录像/计时 | **P2（可省）** | 已有旁证（HARD 档 5.7 s 期间 `[hb]` 不断、按键照常响应） |
| **T2** | 菜单系统 + AI 双向独立难度 + 间隔档位 | **P0（最大块）** | 标题屏→模式→难度/执子/间隔；`game_t` 拆字段 |
| **T3** | HUD 行距重排 | **P0（很小）** | **随 T2 一起做**，别单独改一遍 |
| **T4** | AI 思考卡顿 G1+G2 | **P0** | 人落子立刻刷屏；AI 按层分批刷屏（**主要服务裸机版**）|
| **T5** | CoreMark 编进固件"一起运行"（强版本） | **P0** | 真实跑、真实显示，**禁止写死数字**（约定 58 尤其适用）|

**顺序：T2+T3 → T4 → T5**（T1'a 随手 10 分钟做掉，T1'b 看答辩需不需要）。

> **[!] T1'a 的指派说明（2026-10-14）**：`vblank timeout` 这条**整条留给你**（甲方决定）。
> 你只做"兜底"（日志降级 + 注释/文档写清机制）；**根治**（`rtl/video/video_core.v` 加只读帧计数器）
> 归**视频线**，要**先申请**再动 —— 因为那是 RTL 改动 + 要重出位流。
> 三种方案的对比见 `doc/board/README.md` 的 rev1019 那节表格。

**明确不做**：DDR3、音频、SD 卡、以太网；NES 模拟器（内存不可行）；
**不碰 `rtl/core/` 与 `rtl/bus/`**（发现 CPU/总线侧异常走反馈回路，见 §5）；
`rtl/video/` 的改动也要先申请（vblank 那条就属于这一类）。

---

## 4. 新增纪律（本轮产生）

### 4.1 [!] 别写死"由 RTL / 编译宏决定的数字"（约定 58）

* 已修的例子：横幅主频（`app/main.c`）。
* **还没修的例子（归你，低风险但要做）**：`scripts/demo/addr_map.h:68` 的
  **`#define CPU_HZ 85005100u`** —— 它喂 `scripts/gomoku/hw_port.c` 的 `hw_ticks_per_ms()`
  ⇒ 在 **76.5 MHz 档**下：long-press 的 0.6 s 阈值实际约 **0.67 s**、AI 打印的 `t=…ms` 约**低 10%**。
  * 正解：让 `CPU_HZ` 跟随 `BOARD_SYSTEM_CLOCK_HZ`（没定义时回落到 85,005,100）。
  * [!] **`addr_map.h` 是共享头**（`scripts/demo`、裸机五子棋、video 都用它）⇒ **动之前先申请**，
    并且**必须回归** `run_sim.ps1`（五子棋仿真）与裸机五子棋的按键去抖行为。
  * 纯阈值/显示偏差，**不影响功能** —— 优先级低于 T2~T5。

### 4.2 回归清单（**RT-Thread 四配置是你的**）

```powershell
scripts\rtthread\run_sim.ps1                             # 无 Cache（默认）
scripts\rtthread\run_sim.ps1 -ICache                     # ← 停顿相关 bug 的照妖镜
scripts\rtthread\run_sim.ps1 -DCache
scripts\rtthread\run_sim.ps1 -DCache -ICache
scripts\rtthread\run_sim.ps1 -ICache -LdChk              # load 数据自检 + 规范化事件流（排障用）
```

* **四条都要 PASS**（判据：banner + render/AI 两条线程 + `[hb]` 心跳），每次核对 vvp 首行 `SIM CONFIG:`。
* **为什么是你跑**：RT-Thread 是唯一能抓到"冻结拍"类缺陷的负载（大固件 + 1 ms 定时器中断）。
  只要有人动 `rtl/core/**`，**这条线就是最后一道网**。
* 上板验证（真机，比仿真硬）：`scripts\serial_monitor.ps1 -Port COM4 -Seconds 60`
  → 判据 = `RTL=0x…` 对版 + 两条线程 + `[hb]` 无断 + **能下完一局**。

### 4.3 排障工具（不用自己造轮子）

* `-TrapTrace`（异常/中断，含肇事 pc 与 tval）/ `-ITrace`（指令流 + 双写口）/
  `-LTrace`（访存事件）/ `-PcTrace`（PC 逐拍）/ `-LdChk`（load 数据自检 + 规范化事件流）。
* 对拍：`scripts\itrace_stream_diff.py`（**配对感知，推荐**）/ `scripts\pctrace_diff.py`。
  * [!] **规范化事件流对拍时记住：中断落在哪条指令上是随机的（无害），"被冻结的中断"才有害。**
* 串口工具的小坑（约定 56）：`serial_monitor` 用 ASCII 解码，**≥0x80 的字节在日志里显示成 `?`**
  —— 看到成片 `?` 先 `Format-Hex` 看原始字节，别去源码里找 `?` 字面量。

---

## 5. 文件边界（和乙=CPU/RTL 线并行，**别越界**）

| 你（甲：应用/五子棋/RT-Thread）| 乙：CPU/RTL 线 | 需申请（共享）|
|---|---|---|
| `scripts/gomoku/**`、`scripts/rtthread/{app,bsp}/**`、`scripts/video/**`、五子棋/RT-Thread 固件 | `rtl/core/**`、`rtl/mem/**`、`rtl/bus/**`、CPU 侧 `sim/tests/**` | `scripts/demo/addr_map.h`、`rtl/bus/addr_map.vh`（三处同步）、`rtl/video/**` |

* 发现 CPU/视频侧异常 ⇒ **走反馈回路**（写清"现象 + 复现命令 + 证据"），别自己改。
* 要加新外设/改地址映射 ⇒ 先申请，归集成方裁决。

---

## 6. 怎么跑（速查）

```powershell
# ---- 不需要板子 ----
scripts\gomoku\run_sim.ps1                 # 五子棋端到端仿真
scripts\rtthread\run_sim.ps1 -ICache       # ★ 见 §4.2
scripts\rtthread\build.ps1 -Sim            # 仿真口径固件（100MHz + 短延时）
scripts\rtthread\build.ps1                 # 上板口径固件（85.0051MHz）

# ---- 上板 ----
# 起 JTAG Server：D:\pango\PDS_2022.2-SP6.4\bin\cdt_js.exe -port 65420
# 烧录：Scan Device → Assign New Configuration File → Program（**别只点 Program**，会烧成上次那份）
# 串口：scripts\serial_monitor.ps1 -Port COM4 -Seconds 60   （日志自动落 doc\board\uart_<时间戳>.txt）
# 判据：首行 RTL= 对版；两条线程；[hb] 每 5 s 一条无断；能下完一局
```

> [!] **这颗位流（`90944754`）的横幅会打 `@85.0051MHz`**，而它实际跑 76.5052 MHz ——
> 那是**修复前的固件字面量**，**不是烧错了**（判据看 `RTL=0x20261019`）。

---

## 7. 卡住了怎么办

1. 先看 `CLAUDE.md` 的 **约定 55/56/57/58**（本轮新增）与 `doc/board/README.md` 的 rev1019 那节。
2. 五子棋/RT-Thread 侧的机制问题看 `doc/reports/2026-10-13_taskbook_gomoku_v2.md`（T2~T5 细节）。
3. 怀疑是 CPU/总线侧 ⇒ 按 §5 走反馈，附上 `-TrapTrace`/`-ITrace` 的原始片段。
4. **结论立刻落盘**（报告 + commit），别只留在对话里。
