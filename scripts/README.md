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
scripts\run_riscv_tests.ps1 -ElfDir riscv32-FPGA-pds\riscv-tests-run\build
scripts\run_coremark.ps1 -Iter 1        # 周期数必须仍是 1,529,499
scripts\run_demo.ps1
scripts\run_sim.ps1 -NoWave
```

> `run_riscv_tests.ps1` 默认从 `third_party/riscv-tests` 源码编译（需联网 clone）。
> 只想快速回归时用 `-ElfDir <含 *.elf 的目录>` 跳过编译，直接用现成 ELF。

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

`elf2mem.py` 有两个防呆：
- 两个 hex 的 word 索引一旦相交就**报错退出**（统一存储器下会静默覆盖）
- 已分配(`SHF_ALLOC`)却不属于指令段/数据段的段会**打警告**（避免"指令凭空消失"）

## VSCode 一键入口

`.vscode/tasks.json` 里有三个任务：Run All / Run Current Testbench / Run One Testbench。
