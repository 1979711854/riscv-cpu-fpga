# scripts

> [!] **当前口径（2026-10-19）**：生产档 **76.5052 MHz**；官方交付 **`b45941d6`**
> （CoreMark **352.5**，ITER=**3900**，`Total ticks 846,440,591`，效率 **4.6075**，
> CPU 域 **+0.304 ns / Fmax 78.3269**，LUT **7,740**）。
> 下面脚本说明里出现的 **85.0051 MHz / 365.93 / 351.86 / 232,345** 是 2026-10-16 历史线，
> 只作对照；当前上板请用 76.5052 / ITER=3900 / 352.5。

自动化脚本：编译固件、跑仿真、生成 hex、同步到 PDS 工程。

## 一键脚本（在仓库根目录执行）

| 脚本 | 用途 |
|---|---|
| `run_sim.ps1` | 跑 `sim/` 下全部单测。`-Testbench sim/xxx.v` 跑单个；`-NoWave` 不弹波形；整核测试台加 `-WithCore` |
| `run_riscv_tests.ps1` | riscv-tests rv32ui 全量回归 + 汇总 |
| `run_coremark.ps1 -Iter N` | 编译 CoreMark → 拆 hex → 仿真跑分 |
| `run_demo.ps1` | 演示程序（读按键→写 LED→串口打印）编译 + 端到端仿真 |
| `run_video.ps1` | 彩条固件（填显存画 8 条竖条 + 串口读回自检）编译 + 端到端仿真 |
| `sync_firmware.ps1` | 把 `sim/programs/mem.hex` 同步到 `pds/RV32I_1/` 供 BRAM 初始化 |

> [!] **配置口径（双发射 / 单发射）**：`run_riscv_tests.ps1` / `run_coremark.ps1` / `run_own_tests.ps1`
> **默认双发射**，加 `-Single` 出单发射。测试台靠编译期 `-DDUAL` 选配置、t=0 打印
> `SIM CONFIG: DUAL_ISSUE=`（也进 `sim/programs/results.txt` 首行）；
> `run_demo` / `run_rtthread` / `run_gomoku` / `run_video` 例化 `cpu_top`，**本来就是双发射**。

```powershell
# 例：完整回归（改完 RTL 后必跑，默认双发射）
scripts\run_riscv_tests.ps1                 # 期望 49 PASS / 1 FAIL
scripts\run_coremark.ps1 -Iter 1            # 期望计时区间 232,345 拍（双发射 + EARLY_LD = 板上口径，加 -EarlyLd；A1 前 241,633）
                                            #   脚本默认（不带 -EarlyLd）→ 252,730；单发射 -Single → 303,140
                                            #   带 Cache：加 -DCache -ICache -EarlyLd → 235,628
scripts\run_demo.ps1
scripts\run_sim.ps1 -NoWave
```

> [!] **上板前记得换回 ITER=4280 并同步**：跑过 `-Iter 1` 之后
> `sim\programs\mem.hex` 就是 1 次迭代的固件，直接上板只有几毫秒（85.0051 MHz 板上约 0.004 s）、
> CoreMark 判 invalid。
> ```powershell
> scripts\run_coremark.ps1 -Iter 4280 -SkipSim
> scripts\sync_firmware.ps1
> ```
> **为什么是 4280**：ITER 要按**板上时钟**算 —— 本地盘古板用 PLL 把板载 27 MHz
> 倍频到 **85.0051 MHz**（仿真与远程平台仍是 27 MHz），
> 当前**双发射 + 任务C `EARLY_LD` + A1** 每迭代 **232,345** 拍（A1 前 241,633），
> `4280 × 232,345 ÷ 85,005,100 = 11.70 s`（余量 17%，满足 ≥10 s）。
> [!] **A1 前的跑分档板上实测（历史，2026-10-11/12）**：`994,386,960` ÷ 85,005,100 =
> **11.69797 s / 351.86 CoreMark**，位流 md5 `2ddaf32f`（无 Cache）/
> **`2f7a4d0a`（只开 D-Cache，分数完全相同）**，日志 `doc/board/uart_20261011_225624.txt` /
> `uart_20261012_002541.txt`。
> **I+D Cache 版（A1 后）**（76.5052 MHz，`RATIO0=15.0`，ITER=3800，每迭代 234,706.8 拍）：`891,885,963` ÷ 76,505,200 =
> **11.6578 s / 325.96 CoreMark**，位流 `da8ffd31`，日志 `doc/board/uart_20261013_195230.txt`（A1 前：`894,745,801` → 11.6952 s / 313.63 / `c6b12d95`，日志 `doc/board/uart_20261012_155934.txt`）。
> 历史（**单发射** 85.0051 MHz）：ITER=2740，`996,015,474` ÷ 85,005,100 = 11.7171 s / 233.85（md5 `ae4deea9`）；
> 双发射 ITER=3170 → `994,988,178` → 11.7050 s / 270.82（md5 `5c4893de`）；
> 62.03 MHz `727,018,199` → 11.7203 s / 170.64；49.89 MHz `588,890,651` → 11.8031 s / 140.89。
> 速算式：**`ITER = 目标时长 × 板上时钟 ÷ 每迭代周期数`**，**当前每迭代周期数
> `232,345`**（A1 前 241,633；`EARLY_LD=0` → 252,730；单发射 → 303,140；带 Cache → 235,628）—— 这个数与时钟无关。
> 上板也可以直接走一条龙 `scripts\build_bitstream.ps1 coremark`（生成固件 → 同步 → 综合），
> 加 `-Single` 出单发射回退版位流。

> `run_riscv_tests.ps1` 的三条路，按优先级：
> 1. `-ElfDir <目录>` —— 直接用指定目录里的现成 ELF
> 2. `third_party/riscv-tests` 源码存在 —— 从源码编译（需联网 clone）
> 3. **都不满足 —— 自动回退到随附的基线 ELF `third_party/riscv-tests-elf/`**（50 个，已入库）
>
> 所以**不带参数直接跑就能全量回归**，不依赖网络，也不依赖 `riscv32-FPGA-pds/`。
> 那批 ELF 为什么要入库、怎么重新生成，见 `third_party/riscv-tests-elf/README.md`。

## 辅助文件

| 文件 | 用途 |
|---|---|
| `elf2mem.py` | ELF → `imem.hex`(指令) / `dmem.hex`(数据) / `mem.hex`(合并) / `tohost_addr.hex` |
| `riscv_tests_link.ld` | riscv-tests 链接脚本（重定位到 0x0） |
| `coremark_port/` | CoreMark 的 RISC-V 移植层（`core_portme.c/h`、`ee_printf.c`、`start.S`、`link.ld`） |
| `demo/` | 演示程序（`demo.c`、`start.S`、`link.ld`、`addr_map.h`） |
| `video/` | 彩条固件（`video.c`；复用 `demo/` 的 `start.S`/`link.ld`/`addr_map.h`） |

### 关于 `mem.hex`

统一存储器只初始化**一个**数组，所以 PDS 综合用合并后的 `mem.hex`；
`imem.hex`/`dmem.hex` 保留给 testbench 的 `+IMEM=`/`+DMEM=` 参数用。

`elf2mem.py` 有三个防呆：
- 两个 hex 的 word 索引一旦相交就**报错退出**（统一存储器下会静默覆盖）
- 已分配(`SHF_ALLOC`)却不属于指令段/数据段的段会**打警告**（避免"指令凭空消失"）
- 产物为空时**报错退出**；临时文件清理失败**只警告、不中止**

> 第 3 条是 2026-09-21 修的一个真 bug：原先 `os.remove(_sec.tmp.bin)` 排在 `write_hex()`
> **之前**，而该调用在沙箱/被杀软占用等环境会抛异常 —— 一旦抛出，脚本就在
> **写出 hex 之前**中止，目录里留着上一次构建的镜像。表现是"gcc 成功、脚本成功、
> 上板却跑旧程序"，极难排查。现在清理挪到最后并容错。

## VSCode 一键入口

`.vscode/tasks.json` 里有三个任务：Run All / Run Current Testbench / Run One Testbench。
