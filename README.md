# 基于紫光同创FPGA的RISC-V单周期CPU设计

> 全国大学生嵌入式芯片与系统设计竞赛 —— FPGA赛道  
> 紫光同创选题 · 基于RISC-V指令集CPU设计

## 📌 项目简介

本项目基于紫光同创 **Logos-2 PG2L200H-6FBB676** FPGA芯片，使用 **Verilog** 硬件描述语言，设计并实现一个支持 **RV32I基础整数指令集** 的单周期RISC-V处理器核心。

最终目标是：
- 在PDS中完成综合、布局布线，烧录至开发板运行
- 移植CoreMark跑分程序，验证处理器性能
- 为后续升级为**五级流水线**奠定基础


---

## 📁 目录结构（重要）

克隆仓库后，你的本地目录应该是这样的：

```
riscv-cpu-fpga/
├── README.md              # 项目说明
├── .gitignore             # Git忽略规则（已配置好）
│
├── doc/                   # 📄 文档：数据手册、原理图、控制信号表等
├── rtl/                   # ⚙️ 硬件源码：所有 .v 文件
│   └── top.v              # 顶层模块
├── sim/                   # 🧪 仿真文件：Testbench、波形文件
├── scripts/               # 🔧 自动化脚本
└── pds/                   # 🗂️ PDS工程目录
    └── riscv_cpu/         # PDS工程文件夹（里面是 .pdsproj 等文件）
```



> ⚠️ **注意**：PDS编译生成的中间文件（synth/、impl/、.sbit等）已被 `.gitignore` 屏蔽，**不会**提交到Git仓库，所以你的仓库会很轻量。每个人在自己的电脑上重新编译即可。

---

## 🛠️ 开发环境配置（每位队友必做）

### 1. PDS（紫光同创开发工具）
- 已经安装好的队友：确认版本可用
- 尚未安装的队友：从紫光同创官网下载并安装 **Pango Design Suite**
- 安装路径**不要有中文或空格**

### 2. RISC-V工具链（用于编译C/汇编测试程序）
- Windows推荐使用 **Scoop** 安装：
  ```powershell
  scoop install iverilog gtkwave   # 仿真工具


## 🔄 Git代码管理规范（必读）

**仓库地址**：`https://github.com/1979711854/riscv-cpu-fpga.git`

---

### 📥 首次克隆（每人只做一次）

打开命令行，进入你想存放工程的目录（如 `D:\`），执行：

```powershell
git clone https://github.com/1979711854/riscv-cpu-fpga.git
cd riscv-cpu-fpga
```

---

### 🔁 日常开发流程（每天必做）

#### 第一步：开始工作前，先拉取最新代码

```powershell
git pull origin main
```

#### 第二步：修改代码后，提交并推送

```powershell
git status                 # 查看改了哪些文件
git add .                  # 添加所有修改
git commit -m "描述你做了什么"   # 提交到本地
git push origin main       # 推送到GitHub
```

---

### ⚠️ 如果推送被拒绝（别人先推了）

```powershell
git pull origin main       # 先拉取合并
```

> 如果有冲突，手动解决冲突后，执行：

```powershell
git add .
git commit -m "解决合并冲突"
git push origin main
```

---

### 📝 提交信息格式参考

| 前缀 | 用途 | 示例 |
| :--- | :--- | :--- |
| `feat:` | 新增功能 | `feat: 添加ALU模块` |
| `fix:` | 修复Bug | `fix: 修复PC跳转逻辑错误` |
| `docs:` | 文档修改 | `docs: 更新README` |
| `refactor:` | 代码重构 | `refactor: 优化控制单元代码` |


## 📂 PDS工程如何打开（队友必看）

> **🚀 工程位置**
> 
> 工程文件已经创建好，路径为：
> D:\riscv-cpu-fpga\pds\riscv_cpu\riscv_cpu.pdsproj

### 📝 打开步骤

1. **启动** `Pango Design Suite`
2. 点击菜单栏 **`File`** → **`Open Project`**
3. 浏览到 `pds/riscv_cpu/` 目录，选择 **`riscv_cpu.pdsproj`** 文件
4. 点击 **`打开`** 即可

### 💡 重要提示
  
> PDS工程文件里记录的是 **相对路径**，只要整个仓库目录结构不变，就能正常打开。

## 🔧 芯片型号（已配置，请勿修改）

| 项目 | 值 |
| :--- | :--- |
| **系列** | `Logos-2` |
| **型号** | `PG2L200H-6IFBB676` |

> ⚠️ **这个型号已经配置好了，不要擅自修改**，否则可能导致管脚约束失效，编译通不过。

---

## ⚠️ 常见问题

### Q：PDS打开工程后，找不到 `top.v`？

**A**：检查 `rtl/` 目录下是否有 `top.v` 文件。如果没有，从队友那里同步一下（`git pull`）。如果文件存在但 PDS 没加载，在 Project 窗口中右键 → `Add Source` 手动添加。

---

### Q：我改了代码，但编译结果和队友不一样？

**A**：这是正常的。PDS 的编译中间文件（`synth/`、`impl/` 等）不会被 Git 同步。每个人在本地重新编译即可。

---

### Q：如何确认自己的模块功能正确？

**A**：每个子模块都要写独立的 Testbench 进行仿真验证，**不要等所有模块写完再一起调试**。仿真通过后再提交代码。