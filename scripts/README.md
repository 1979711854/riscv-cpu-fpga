# scripts

自动化脚本：编译固件、跑仿真、生成 hex、同步到 PDS 工程。

## 一键脚本（在仓库根目录执行）

| 脚本 | 用途 |
|---|---|
| `run_sim.ps1` | 跑 `sim/` 下全部单测。`-Testbench sim/xxx.v` 跑单个；`-NoWave` 不弹波形；整核测试台加 `-WithCore` |
| `run_riscv_tests.ps1` | riscv-tests rv32ui 全量回归 + 汇总 |
| `run_coremark.ps1 -Iter N` | 编译 CoreMark → 拆 hex → 仿真跑分 |
| `run_demo.ps1` | 演示程序（读按键→写 LED→串口打印）编译 + 端到端仿真 |
| `sync_firmware.ps1` | 把 `sim/programs/mem.hex` 同步到 `pds/RV32I_1/` 供 BRAM 初始化 |

```powershell
# 例：完整回归（改完 RTL 后必跑）
scripts\run_riscv_tests.ps1                 # 期望 49 PASS / 1 FAIL
scripts\run_coremark.ps1 -Iter 1            # 期望计时区间 358,846 拍（测试台总周期 1,462,898）
scripts\run_demo.ps1
scripts\run_sim.ps1 -NoWave
```

> ⚠️ **上板前记得换回 ITER=820 并同步**：跑过 `-Iter 1` 之后
> `sim\programs\mem.hex` 就是 1 次迭代的固件，直接上板只有 0.014 秒、CoreMark 判 invalid。
> ```powershell
> scripts\run_coremark.ps1 -Iter 770 -SkipSim
> scripts\sync_firmware.ps1
> ```

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
