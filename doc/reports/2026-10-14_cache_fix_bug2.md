# Cache + RT-Thread 挂死 —— 根因 #2 已修（2026-10-14）

> 接 `2026-10-14_cache_fix_bug1.md`（#1：ID/EX 清零漏 `mem_ready_int` 门控，已修）。
> 上一轮的归因见 `2026-10-14_cache_rtthread_sim_bisect.md`。
>
> 一句话：**CSR 写（EX 级提交）漏了 `mem_ready_int` 门控** —— 访存冻结那一拍 CSR 已经写进
> 寄存器组，而冻结让这条指令**仍旧停在 EX**，于是放开那一拍 `alu_result` 里的
> `csr_rdata` 已经是【写后】的值，`csrrw rd, csr, rs1` 的 **rd 拿到新值而不是旧值**。
> RT-Thread 的中断入口/出口各有一条 `csrrw sp, mscratch, sp`（**rd 就是 sp**），冻结撞上它
> ⇒ **sp 不切到中断栈**、处理函数跑在线程栈上；出口那条再把 `mscratch` 写坏 ⇒ 之后每次中断
> 的 sp 都在漂移，最终踩坏内核链表（`_timer_remove` 的 next 指针）⇒ `cause=6` 死循环转储。
> 已修（`core.v` 1 行 + `mret` 同族 1 行），`DESIGN_REV = 0x2026_1019`。

---

## 1. 定位方法（先说工具，可复用）

### 1.1 先证伪上一轮的假设：**load 数据路径是好的**

上一轮从 `trap_tval`（=`0x00812627`、ASCII `"vend"`）反推"某次 load 返回了隔壁的内容"。本轮先给
`tb_rtthread` 加了 **`-DLDCHK`** 把它变成可判定的问题（`sim/tb_rtthread.v`）：

* 用一个**影子寄存器**镜像 core 的 MEM/WB 级（**同一门控 `mem_ready_int`**），记下 WB 级这条
  load 的 `(pc, 地址, funct3, 地址低位)`；
* **期望值直接取存储器真值** `mem0[addr]`（仿真行为模型），并与 `mem_bus` 的 B 口读在**同一个沿**
  采样，再按 funct3 解包 —— 对 RAM load 必须逐位相等；
* 不等就打印（前 40 条）。

**结果（`-ICache`，修复前的 RTL）：297,379 条 RAM load / 0 条错。**
⇒ **"某次 load 返回错数据"这个假设被推翻** —— 数据通路（`mem_rdata` / `wb_rdata_snap` /
`ld_snap`）是好的，嫌疑必须挪到"**寄存器的值**从别的路径被写坏"或"控制流跑偏"上。

> 这一步是本轮的关键：它把范围从"整条访存通路"缩到"非 load 的写回 + trap 路径"。

### 1.2 规范化访存事件流 + 对拍：第一条分歧点

同一开关还会落一份**规范化**事件流 `rtthread_ldtrace.txt`（load 记在它的 WB 沿、store 记在
MEM 沿，**停顿期间的重复自动折叠**）⇒ 无 Cache 与带 Cache 两份可以直接逐行 diff：

| | 无 Cache（金标准，PASS） | 带 I-Cache（修复前，挂） |
|---|---|---|
| 首处**结构**分歧 | event **33656** | 同 |
| event 33655 | `S 0x5908 0x8002163b` | 同（逐字节一致） |
| event 33656 | `L 0x58fc 0x0000b574` | `S 0x0000003c 0x0000b4ac deadbeef` ← **中断入口存帧** |

* 前 33,655 条事件**逐条一致** ⇒ 程序在分歧点之前完全同步；
* 分歧点**恰好是第一次"撞上访存冻结"的定时器中断**（`0x3c..0xb4` 就是 `SW_handler`
  的存帧序列，`interrupt_gcc.S:62-98`）。

⇒ **分歧不在 load，在中断**。（注：中断本身落在哪条指令上是随机的、无害的；**有害的是
中断期间被冻结**。）

---

## 2. 根因

`rtl/core/core.v`（EX 级 CSR 提交处）：

```verilog
// 修前
assign csr_wr_en = csr_wr_en_raw && !trap;
// 修后
assign csr_wr_en = csr_wr_en_raw && !trap && mem_ready_int;
```

CSR 是**在 EX 级提交**的（约定 21：`csrw mepc` 与 `mret` 只隔 1 条，从 WB 提交会读到复位值）。
而"**这条指令离开 EX**"这件事发生在 **`mem_ready_int=1` 的那个沿**（`EX/MEM <= ID/EX` 用的是
同一个条件）。两者不同源时：

```
T   : EX 里是 csrrw rd, csr, rs1；mem_ready_int=0（访存冻结）
      → EX/MEM 【保持】（约定 56 的修复正是让它保持）
      → 但 csr_wr_en 不管冻结：CSR 在 T→T+1 沿【已经写进去了】
T+1 : 同一条指令【还在 EX】（冻结没平移）
      → csr_rdata 读到的是【写后】的值
      → mem_ready_int=1（放开）→ EX/MEM <= alu_result = csr_rdata(写后)  ✗
```

⇒ `csrrw` / `csrrs` / `csrrc` 的 **rd 被写成"写后的 CSR 值"**（规范要求旧值）。
这**与约定 51 的乘法器使能、约定 56 的 ID/EX 清零是同一族**：EX 级副作用必须与"离开 EX"同源。

**为什么只有 RT-Thread 挂**：

| 配置 | 有冻结吗 | 有"写 CSR + 用旧值(rd≠x0)"吗 | 结果 |
|---|---|---|---|
| CoreMark（裸机、无 trap） | 无 Cache 时没有；I+D 时有 | **没有**（CoreMark 只 `csrr` 只读，`csr_wr_en=0` ⇒ 无写、无副作用） | 过 |
| riscv-tests | 几乎无（代码 1~2 KB，缺失少） | 有，但撞上冻结概率≈0 | 过 |
| **RT-Thread** | **I-Cache 冷启动几乎每拍缺失 ⇒ 每 2 拍冻 1 拍** | **有：中断入口/出口各一条 `csrrw sp, mscratch, sp`（rd=sp）** | **挂** |

`third_party/rt-thread/libcpu/risc-v/common/interrupt_gcc.S`：

```asm
101:  csrrw sp, mscratch, sp      /* 切到中断栈：sp ← (旧 mscratch)，mscratch ← (旧 sp) */
...
109:  csrrw sp, mscratch, sp      /* 切回线程栈 */
```

冻结撞上 101 时：mscratch 写对了、**sp 没切**（拿到的是写后的 mscratch = 旧 sp）⇒ 处理函数
跑在**线程栈**上；出口那条再把 `mscratch` 写成处理函数剩下的 sp ⇒ **之后每次中断 sp 都漂移**，
把 128 B 存帧 + C 调用链写到半随机位置 ⇒ 踩坏内核对象 ⇒ 链表 next 指针变成垃圾（`a3`）⇒
`sw a4,4(a3)` 未对齐 ⇒ `cause=6` 死循环转储。**这就是 `trap_tval` 看起来像"隔壁内容"的原因**：
它不是 load 读错，是**链表被写坏**。

---

## 3. 决定性证据：中断处理函数的栈帧落点

同一处（第一次撞冻结的中断），看处理函数**后续**的 store 落在哪（`rtthread_ldtrace.txt`）：

| 运行 | 存帧（`SW_handler`，线程栈） | 存帧**之后**的 C 帧 | 含义 |
|---|---|---|---|
| 无 Cache（金标准） | `0xb49c..0xb514` | **`0xffec`** | sp 切到了中断栈（`__rt_rvstack` 顶 = `0xfff0`）✓ |
| `-ICache`（修前） | `0xb49c..0xb514` | **`0xb490`** | **sp 没切**，处理函数跑在线程栈上 ✗ |
| `-ICache`（修后） | 同上 | **`0xffec`** | 与金标准**同址** ✓ |
| 无 Cache（修后，对照） | 同上 | `0xffec` ✓ | 逐位不变 ✓ |

三条完全对上，根因成立。

---

## 4. 修复

`rtl/core/core.v`，两处（都加了注释说明"EX 级副作用必须与离开 EX 同拍"）：

1. `assign csr_wr_en = csr_wr_en_raw && !trap && mem_ready_int;` ← **真正的 bug**
2. `wire mret_commit_ex = mret_commit && mem_ready_int;` 送给 `csr_file` 的 `.mret()`
   ← **同族**：`mret` 的 `mstatus.MIE ← MPIE` 也不该在冻结期间重复施加
   （重复施加时 MPIE 已被写成 1，若原 MPIE=0 会把 MIE 错误置 1）。重定向仍走 `mret_commit`
   （冻结时 `fetch_addr` 本来就退回 `if_addr_d`，等价）。

`DESIGN_REV` → **`0x2026_1019`**（`rtl/core/csr_file.v`，约定 42）。

---

## 5. 验证

### 5.1 RT-Thread 四种配置（`scripts\rtthread\run_sim.ps1`，`-NoBuild`，固件与归因轮同一份）

| 配置 | 修前 | 修后 |
|---|---|---|
| 无 Cache | PASS | **PASS**（168 B，逐位不变） |
| 只开 D | 崩（走得较远） | **PASS** |
| 只开 I | 崩（13 B） | **PASS** |
| D + I | 崩（13 B） | **PASS** |

四条都出现 banner + render/AI 两条线程 + `[hb]` 心跳。`-DLDCHK` 全程 **0 条错 load**。

### 5.2 四条基线（逐位口径都没动）

| 回归 | 结果 |
|---|---|
| `run_riscv_tests.ps1 -ElfDir third_party/riscv-tests-elf` | **49 PASS / 1 FAIL / 0 TIMEOUT**（FAIL = `ma_data` 哨兵） |
| 同上 `-DCache -ICache -EarlyLd` | **49 / 1 / 0**（FAIL = `ma_data`） |
| `run_coremark.ps1 -Iter 1 -EarlyLd` | **`Total ticks = 232,345`**，CRC `e9f5/e714/1fd7/8e3a` 一字不差 |
| `run_own_tests.ps1 -DCache -ICache -EarlyLd` | **exceptions / timer_irq 2 PASS / 0 FAIL** |

⇒ 修复**只影响"冻结拍撞上 EX 级 CSR 副作用"这一角**；无 Cache（`mem_ready_int` 恒 1）逐位不变。

---

## 6. 本轮新增工具

```powershell
scripts\rtthread\run_sim.ps1 -ICache -LdChk   # load 数据自检 + 规范化事件流（问"哪条 load 读错了"）
```

* 落盘 `rtthread_ldtrace.txt`：`L <idx> <pc> <addr> <f3> <got> <exp> <bad>` /
  `S <idx> <pc> <addr> <wdata> <byte_en>`；
* load 记在**它的 WB 沿**、store 记在 **MEM 沿**，停顿期间的重复自动折叠 ⇒
  **无 Cache 与带 Cache 两份可以直接逐行 diff**，第一条不同即首次分叉。
  （`.gitignore` 已覆盖 `rtthread_*trace*.txt`。）
* [!] 这里的 `-ICache -LdChk` 是在 `sim/` 之外跑，产物落在仓库根；别入库。

---

## 7. 顺带查清的（省后面查的人）

1. **`scripts\run_sim.ps1`（Run All）有三处既有断点**（都与本次改动无关，逐条都验过：
   这些测试台都不编 `core.v`）：
   * `tb_gomoku.v` **漏在 `$externalProgramTbs` 排除表外** ⇒ Run All 走到它报
     `Unknown module type: cpu_top`，**排在它后面的全部不跑**（看起来像"只坏了一个"）。
     **已补进排除表**（该表的注释本来就要求"跟着新增 tb 一起维护"）。
   * `tb_ppu.v` / `tb_video*.v` 需要 `rtl\video` 那六个文件，而 Run All 只编
     `rtl\core / periph / bus` ⇒ 同样报 `Unknown module type`。**未动**（要动就得给
     Run All 加"按测试台补编目录"的机制，属另一件事）。
   * `tb_multiplier.v` 是**约定 52（A1：II=1 流水线）之前**的握手测试台，仍在等 `done` 握手
     ⇒ `checks=840 errors=840`。**未动**（要按新接口重写，属另一件事）。
   * Run All 里实际跑到的：`tb_alu_div` / `tb_alu_inst` / `tb_amo` / `tb_control` / `tb_gpio`
     **全 PASS**。
2. **无 Cache 并不是"绝对没有 `mem_ready_int=0`"** —— 开 Cache 才是主要来源，但 **AMO 占住
   MEM 期间 `amo_hold` 也会压 `mem_ready_int`**。也就是说这一刀对"AMO + 写 CSR 指令相邻"的
   序列同样是对的（只是本固件不走 AMO）。

---

## 8. 口径更新

* `c10a2478`（rtthread + I+D @76.5）与 `9feaa089`（rtthread + D-only @85）**仍是旧 RTL、
  仍标"勿烧"**；**但它们记录的两条根因都已修掉**。`9feaa089` 另有时序问题
  （CPU 域 −0.177 ns / 13 失败端点），**即使功能修好也塞不进 85 MHz**。
* **[OK] 新的 Cache 位流已出（2026-10-14 13:48，rev 1019）**：
  `bitstreams/rtthread_dual_aext_ms_earlyld_a1_gomoku_g3_idcache_76mhz_rev1019_90944754.sbit`
  —— rtthread + I+D @76.5052 MHz（约定 50 的四件套，**构建后已全部还原**：
  `RATIO0=13.5` / `UART_DIV=738` / `BOARD_SYSTEM_CLOCK_HZ=85,005,100` / 生产 `mem.hex`）。
  * 网表自证（约定 46）：`dcache` 1190 / `icache` 1216 / `tag0` 196 ✓；
  * **时序全过**：`All Constraints Met`，CPU 域 **+0.534 ns / 0 失败端点（18,997）**，
    hold +0.147，两条 CDC 也 0 失败 ⇒ 全设计 setup/hold 0 失败端点；
  * **首行自证 `RTL=0x20261019`**，**[OK] 2026-10-14 13:59 已上板（串口侧通过）**。
  * **[OK] 横幅自洽版已重出（14:34）**：`..._rev1019_53b81dfe.sbit` —— **RTL 与 `90944754`
    逐位相同**（网表 `dcache`1190/`icache`1216/`tag0`196、CPU 域 +0.534 ns / 0 失败端点 18,997、
    `All Constraints Met` 全都一致），**只换了固件**（横幅主频改成从 `BOARD_SYSTEM_CLOCK_HZ` 算）
    ⇒ 这次会打 `@76.5052MHz`。**推荐烧这颗。**
  * **[!] 顺带做了个实验：把 85 MHz 生产档（Cache 全关）也用 rev1019 重出** ——
    两颗（CoreMark `aad1e2ac` / rtthread `382ce876`，两次独立运行）**都是
    CPU 域 −0.153 ns / 16 失败端点**（`Some Constraints Violated`），而 rev1017 的
    `bcd8fdd2` 是 **+0.068 / 0** ⇒ **功能虽然逐位等价（§8 那条证明），但时序上换不过去**
    （那两处 AND 加在 `mem_ready_int` 这条本来就很晚的使能信号上）。
    **⇒ 生产/交付档继续用 rev1017；需要这两处修复的"带 Cache"档就是已修好并上板验证的 `53b81dfe`。**
* **[OK] 上板实测（`doc/board/uart_20261014_135935.txt`）**：`RTL=0x20261019`（RT-Thread 侧与五子棋侧
  都自证）+ render/AI **两条线程都起来** + `[hb] alive, uptime 5000…20000 ticks` **每 5 s 一条、
  单调递增、全程无断** ⇒ **"带 Cache 必挂"的组合现在通了**（对照修复前：`c10a2478` 死在 AI 第一手后的
  棋盘快照、`9feaa089` 卡在 `heap = 9368 bytes` 循环重启）。
  * 时钟是 76.5052 而非 85 的旁证：串口文本在 115200 下完全可读（`UART_DIV=664` 只对 76.5 MHz 成立）。
  * **追加验证（14:11，`uart_20261014_141147.txt`）**：真按键**完整下完一局并判出 `WHITE wins`**；
    AI 线程真在算（HARD `nodes=10592 depth=6 t=5737ms`）；**用户接 HDMI 显示器下棋正常**
    ⇒ "落子/对局 + 显示侧"两项也从"未验"转成"已验"。
  * [!] 踩到的坑（源码已修 + **位流已重出 `53b81dfe`**，见 §8）：横幅第 10 行打 `@85.0051MHz` ——
    `scripts/rtthread/app/main.c` 把主频**写死在字符串里**，与位流/时钟无关，看着像烧错位流。
    已改成从 `BOARD_SYSTEM_CLOCK_HZ` 算。**判位流永远看 `RTL=` 行。**
* **生产/交付档继续用 Cache 全关**（五子棋 `8894cdcb` / 跑分 `bcd8fdd2`）—— 本次修复对它们是
  **逐位等价**的（`mem_ready_int` 恒 1），但 RTL 变了 ⇒ 新位流自证 `RTL=0x2026_1019`。
* 高阶任务① 的答辩口径可**从"会挂、默认关"升级为**："两条功能缺陷（ID/EX 清零门控、
  CSR 写门控）已定位并修复；Cache 在功能上可用，仍是**负收益**（分数贡献 ≈0，要降频才能塞进
  时序）⇒ 默认关"。**但"Cache 可用"这句话，必须先有 rev ≥ 0x2026_1019 的位流上板跑通**。
