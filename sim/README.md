# sim

功能仿真：testbench、程序(hex/bin)、波形。PDS 自带仿真器配置说明放这里。

- 计划文件：`tb_core.sv`（顶层测试台）、`programs/`（跑在 CPU 上的测试程序 hex）

## 一键跑所有 tb_*.v 测试台并查看波形

仓库自带的 VS Code 任务入口是：

```json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "Run All Verilog Simulations and Waveforms",
      "type": "shell",
      "command": "powershell",
      "args": [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "${workspaceFolder}\\scripts\\run_sim.ps1"
      ]
    }
  ]
}
```

执行时，脚本会自动发现 `sim/` 下所有 `tb_*.v` 文件，逐个用 `iverilog` 编译、`vvp` 运行，并在仿真生成对应 `vcd` 文件后以无窗口方式启动 `gtkwave` 展示波形。
