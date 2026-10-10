# 迁移任务 M · 五子棋跑在 A 扩展 CPU 上

> 日期：2026-10-08　工程：`D:\riscv-cpu-fpga_ac`（分支 `master`）
> 前置任务：`doc/reports/2026-10-08_taskbook_A_rv32a.md`（**必须先完成 T0~T4**）
> **本文自包含** —— 只跑 PC 端与仿真就能完成。

---

## 0. 一句话现状

**好消息：五子棋源码已经在 ac 仓库里了，且与 merged 仓库完全一致。**
迁移的实质是**把编译目标从 `rv32im` 改成 `rv32ima`**，再跑通验证。

**这条任务的价值**：五子棋本身不含原子指令（纯单线程），
所以「能跑在 A 扩展 CPU 上」证明的是 **A 扩展没有破坏既有应用**——
这比跑通 CoreMark 更有说服力，因为 CoreMark 同样不含 AMO 指令。

### 已经做到的（不是待办）

| 项 | 状态 |
|---|---|
| `scripts/gomoku/` 全套源码 | **已在 ac 仓库**，与 merged **逐字节相同**（`diff -rq` 无输出）|
| CPU 内核 | **已是 A 扩展版**（`core.v`/`control.v` 含 AMO）|
| 五子棋单测 | 270 项（在 merged 上全过）|

### [!] 关键事实：两个仓库的 RTL 差异**只有A 扩展**

我逐文件核对过：

```
regfile.v    相同        ← 没动
csr_file.v   相同        ← 没动
alu.v        相同        ← 没动
core.v       不同        ← 只有 AMO 相关（19 处 AMO / 22 处 amo 符号）
control.v    不同        ← 只有 20 行 AMO 译码
```

**所以不存在"合并两个内核"的问题** —— ac 仓库的内核已经是最终形态。

---

## 1. 三条命令开工

```powershell
cd D:\riscv-cpu-fpga_ac
scripts\gomoku\run_test.ps1      # 五子棋 270 项单测
scripts\gomoku\play.ps1          # PC 端对弈
scripts\gomoku\run_sim.ps1       # 端到端仿真（真 CPU，真慢，20~50 分钟）
```

---

## 2. 任务清单

| # | 任务 | 优先级 | 预计 |
|---|---|---|---|
| **M0** | 改 `-march=rv32im` → `rv32ima` | **P0** | 2 分钟 |
| **M1** | 交叉编译零警告 + 270 项单测全过 | **P0** | 10 分钟 |
| **M2** | 对比固件体积，确认没超32 KB 硬墙 | **P0** | 5 分钟 |
| **M3** | 端到端仿真跑通五子棋 | **P0** | 50 分钟 |
| **M4** | 同步更新 `expectLines` 守卫 | P1 | 5 分钟 |

---

## 3. M0 · 改编译目标

**文件**：`scripts/gomoku/build.ps1:54`

```diff
-    "-march=rv32im", "-mabi=ilp32", "-O2", "-mcmodel=medany", "-msmall-data-limit=0",
+    "-march=rv32ima", "-mabi=ilp32", "-O2", "-mcmodel=medany", "-msmall-data-limit=0",
```

**同时改掉第 51 行的注释**（它写着「`-march=rv32im`：M 扩展本来用得上」，
现在多了一个 A，得说明为什么用不上）：

```c
# -march=rv32ima：A 扩展（amoswap/lr/sc）已接入CPU。
#   但五子棋是【纯单线程】应用，源码里没有 amoswap/amoadd/__sync_*，
#   编译器也不会凭空生成 —— 所以 A 扩展在这份固件里【跑但不用】。
#   这正是这条任务的意义：证明 A 扩展【没有破坏既有应用】。
#   （CoreMark 同样不含 AMO 指令，两者互为佐证。）
```

> [!] **只改这一处**。不要动 `-mabi`、`-O2`、`-mcmodel`、`-msmall-data-limit`
> —— 它们与迁移无关，改了会污染对比基准。

---

## 4. M1 + M2 · 验证与体积

### M1

```powershell
scripts\gomoku\run_test.ps1
```

**判据**：270 项全过 + 交叉编译零警告。

**若报错 `unrecognized opcode ... extension 'zaamo' required`**：
说明工具链不认 `a` 扩展，检查 `riscv-none-elf-gcc --version`
（需要 15.x 及以上；本项目用 xpack-riscv-none-elf-gcc-15.2.0-1）。

### [!] 我已经替你实测过了（2026-10-08）

在 ac 仓库里用 `rv32ima` 把 `scripts/gomoku/*.c` **全部交叉编译过一遍**：

```
$ riscv-none-elf-gcc -march=rv32ima -mabi=ilp32 -O2 \
      -mcmodel=medany -msmall-data-limit=0 \
      -Iscripts/gomoku -Iscripts/demo -c <每个 .c>

结果：全部编过，零错误。
唯一警告：render.c:121 "null character(s) preserved in literal"
          —— 这是【既有问题】，与 march 无关
             （见提交 c94e8a1，改的是 HUD 残字那件事）
```

**所以 M0/M1 风险很低。** 唯一要注意的是编译时**必须带 `-Iscripts/demo`**，
否则 `hw_port.c` / `video_port.c` 会报 `addr_map.h: No such file`。
正式的 `build.ps1` 里已经有了，但你若手动编译别忘了。

### M2 体积核对（**32 KB 是硬墙**）

```powershell
scripts\gomoku\build.ps1 -Firmware
# 看打印出来的 .text / .data / .bss 合计
```

**判据**：合计 **≤ 22,507 字节**（原 `rv32im` 的基线）。

> [!] 五子棋不含原子指令，所以理论上**体积几乎不变**（±100 字节内）。
> **若明显变大，说明有意外的东西被引进来了** —— 查是不是误加了
> `RT_USING_STDC_ATOMIC` 之类会拉进库的宏。

---

## 5. M3 · 端到端仿真

```powershell
scripts\gomoku\run_sim.ps1      # 慢，20~50 分钟，耐心等
```

**判据**：五子棋在真 CPU 上跑通，出牌/ AI 应手 / 胜负判定正常。

**若仿真挂死**：先确认不是 AMO 的问题 ——

```powershell
# 快速判别：把 march 改回 rv32im 再跑一次
# 若 rv32im 能过、rv32ima 挂 => 是 A 扩展的锅，回去看任务书 A 的 T0 trace
# 若两个都挂   => 与 A 扩展无关，是ac 仓库本身的问题
```

---

## 6. M4 · 更新守卫

`expectLines` 是固件大小的守卫。**M2 改了 march 后它可能会拦你**。

- 那是守卫在工作，**不要删它**
- 按 M2 实测的 `mem.hex` 行数更新它
- 更新后 `run_test.ps1` 必须仍然全过

---

## 7. [!] 一条纪律：先确认基线

**动手前先在 ac 仓库跑一次 `scripts\gomoku\run_test.ps1`。**

> 我本人今天在这个项目上栽过：跑 CoreMark 时漏了 vvp 的 `+ITER/+IMEM/+DMEM` 参数，
> 跑 12 分钟不出结果，误判成「设计引入死锁」，实际**基线也一样**。
> **动代码前先确认基线本身能跑通**，否则后面所有对比都不可信。

---

## 8. 硬指标汇总

| 项 | 判据 |
|---|---|
| 五子棋单测 | **270 项全过** + 交叉编译零警告 |
| 固件体积 | **≤ 22,507 字节** |
| 端到端仿真 | 五子棋跑通 |
| 原有基线 | riscv-tests **49/1/0**、CoreMark **313,886**、RT-Thread **4 OK/0 FAIL** |

> **最后一行最重要**：迁完之后要把四条基线**全部重跑一遍**。
> 证明 A 扩展不仅能跑新东西，**而且没弄坏旧东西**。

---

## 9. 与其他任务的关系

| 任务 | 仓库 | 关系 |
|---|---|---|
| **任务 A**（修 AMO 缺陷）| `riscv-cpu-fpga_ac` | **本任务的前置**，必须先做完 T0~T4 |
| 任务 C（五子棋 G1/G2）| `riscv-cpu-fpga_merged` | **并行，互不依赖** |

**两个包不要合并。** ac 仓库里已经有完整的 `scripts/gomoku/`，
直接在这个仓库里做迁移即可，不需要从 merged 复制任何东西。

---

## 10. 交付

```powershell
git status                 # 干净
git log --oneline          # 每个提交都能跑通 270 项单测
scripts\gomoku\run_test.ps1
```

提交信息里写清：**改了 march、实测体积、四条基线的数字**。

---

## 11. 这条任务的意义（写给评委看）

「五子棋能跑在带 A 扩展的 CPU 上」证明的是**兼容性**：

- A 扩展是**新增能力**，不该让任何既有应用失效
- 五子棋与 CoreMark **都不含 AMO 指令**，但两者分别代表**应用层**与**benchmark 层**
- 两者都在 `rv32ima` 下跑通且数字不变 ⇒ **A 扩展对既有程序零影响**

这条结论比「AMO 自己能用」更难，也更有价值 ——
因为它是**回归**性质的证据，而 AMO 能用只是**正向**证据。