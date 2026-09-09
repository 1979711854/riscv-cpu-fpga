# scripts

自动化脚本：编译 RTL、启动仿真、生成 hex、批处理。示例：

- `make_hex.py`   汇编/编译出的机器码转 PDS 可加载的 hex
- `run_sim.cmd`   一键启动 PDS/Modelsim 仿真的批处理

## VSCode 一键仿真与波形查看

仓库已经加入两项自动化入口：

1. 通用脚本：`scripts/run_sim.ps1`
2. VSCode 任务：`.vscode/tasks.json`

使用方法：

```powershell
# 进入仓库根目录
cd d:\riscv-cpu-fpga

# 在 VSCode 终端中执行：
# Terminal -> Run Task -> Run All Verilog Simulations and Waveforms
# 或直接在任务面板选择该任务
```

任务默认会自动枚举 `sim/` 目录下所有 `tb_*.v` 测试bench 文件，逐个执行：

```powershell
iverilog -g2012 -I rtl/core -o <testbench>.vvp <testbench>.v rtl/core/*.v
vvp <testbench>.vvp
gtkwave <testbench>.vcd
```

这意味着：只要新增一个 `tb_*.v` 文件，保存后重新执行任务即可自动编译、运行、并打开对应波形文件。注意：`tb_template.v` 是模板文件，不参与自动扫描。
