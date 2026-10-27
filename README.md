# glmu — GLM Coding Plan 用量查询

一行命令查看智谱（bigmodel.cn）GLM Coding Plan 套餐用量，覆盖三个限额维度：

- 周额度
- 5 小时滚动窗口
- 订阅周期额度池（含分模型用量明细）

支持多 Profile 一键并发总览，并附带一个 Windows 桌面悬浮小组件。

## 目录结构

```
├── glm_usage_query.py   # 单 Key 用量查询（纯文本 / Markdown 输出）
├── glm_usage_all.py     # 多 Profile 用量一键总览（终端排版 / JSON 输出）
└── windows/
    ├── glmu_widget.ps1  # Windows 悬浮小组件（WPF，置顶可拖动，可停靠屏幕角落）
    └── glmu_widget.vbs  # 双击启动器（隐藏控制台窗口，等待 WSL 就绪）
```

## 环境要求

- Python 3.8+，仅标准库，无需 `pip install` 任何依赖
- Windows 小组件需要 WSL2：小组件通过 `wsl.exe` 调用 WSL 内的 Python 脚本取数

## 快速开始

### 1. 单 Key 查询

```bash
export ANTHROPIC_API_KEY=<你的智谱 API Key>   # GLM Coding Plan 订阅对应的 Key
python3 glm_usage_query.py                    # 纯文本输出
python3 glm_usage_query.py --markdown         # Markdown 表格输出
```

查询失败（Key 无效、非 Coding Plan 套餐、网络异常等）时向 stderr 输出错误并返回退出码 1。

### 2. 多 Profile 总览

```bash
python3 glm_usage_all.py               # 默认扫描 ~/.claude/profiles 下文件名含 glm-flash 的 *.json
python3 glm_usage_all.py -p glm        # 自定义文件名匹配关键字
python3 glm_usage_all.py -d <目录>     # 自定义 profile 目录
python3 glm_usage_all.py --json        # JSON 输出（供程序调用，如 Windows 小组件）
```

输出说明：

- 进度条与百分比按已用量配色：<60% 绿、60%~85% 黄、≥85% 红
- 存在已用 ≥80% 的维度时，末尾输出"接近限额"汇总提醒
- 非终端或设置 `NO_COLOR` 时自动关闭颜色
- 退出码：全部 profile 成功为 0，任一失败为 1

### 3. Windows 悬浮小组件

```text
双击 windows/glmu_widget.vbs 即可启动（启动后自动执行首次查询）
```

- **开机自启**：`Win+R` → 输入 `shell:startup` → 回车，把 `glmu_widget.vbs` 的快捷方式放进去
  （登录时 WSL 可能尚未就绪，启动器最多等待约 60 秒）
- **角落停靠**：启动时带 `-Dock BottomLeft` 可把小组件贴死在屏幕左下角（另可选 `BottomRight` /
  `TopLeft` / `TopRight`）。按**小组件所在显示器**的工作区计算（启动即停靠时取记忆位置所在屏，
  即常用屏）——任务栏在该屏顶部时工作区底边即屏幕底边，停靠后与其他窗口互不遮挡。
  停靠选择会记忆，之后不带参数启动也自动恢复停靠；
  按住标题栏拖动即解除停靠，或显式传 `-Dock None` 恢复自由悬浮。vbs 启动器参数原样透传，
  快捷方式目标可写 `wscript.exe "...\windows\glmu_widget.vbs" -Dock BottomLeft`
- **自动刷新**：默认每 60 秒静默查询一次（启动即查首次；`-AutoRefreshSec <秒>` 可调，`0` 关闭），
  刷新期间不打扰状态栏显示
- **状态栏摘要**：标题栏右侧常驻显示各订阅 5 小时窗口已用百分比，每个订阅一枚**身份色圆角 chip**
  （底色与展开卡片同色系、按订阅名哈希稳定取色，三个订阅互不相同），chip 内**上下两行**：
  上行为简写 `01-w`/`02-z`/`03-a`（序号 + 首字母，统一蓝色），下行为百分比（按已用阈值绿/黄/红着色）；
  无该维度的订阅收起下行只显示简写，查询失败下行标 `✗`；悬停 chip 可看该订阅剩余额度与重置点，
  悬停整体可看更新时间
- **交互**：
  - 点击标题栏 → 手动刷新（折叠状态下点击 → 展开并刷新）
  - 点击内容区 → 折叠为标题药丸
  - 按住标题栏拖动 → 移动窗口（位移 >3 DIP 判定为拖动）；停靠态下拖动即解除停靠
  - `Esc` 或 `×` → 关闭
- 窗口置顶、无边框；位置、折叠状态与停靠选择记忆在 `%LOCALAPPDATA%\glmu_widget.json`
- 重复启动不会开出第二个窗口，而是把已有窗口弹到前台
- 停靠态下折叠/展开或每轮刷新导致高度变化时自动重贴角（停靠边钉死不留缝）；
  显示器插拔/切换主屏时停靠态重贴角、自由态窗口漂出可见区则召回工作区右上角

## 配置说明

密钥有两种提供方式，均不进入本仓库：

1. **环境变量**：`ANTHROPIC_API_KEY`（单 Key 查询 `glm_usage_query.py` 使用）
2. **Profile 文件**：`~/.claude/profiles/*.json`，文件内任意嵌套层级存在
   `ANTHROPIC_AUTH_TOKEN` 或 `ANTHROPIC_API_KEY` 字段即可被 `glm_usage_all.py` 识别

## 安全说明

- API Key / Token 仅从环境变量与本地 profile 文件读取，任何输出中都不会打印明文
- 查询调用智谱官方只读监控接口，不产生扣费或配置变更

## 已知限制

- 小组件的查询命令默认从脚本自身位置（`\\wsl.localhost\<发行版>\...\windows`）自动推导，
  要求仓库位于 WSL 文件系统内；若把 `glmu_widget.ps1` 拷到 Windows 本地磁盘运行，
  需通过 `-WslCommand` 显式指定查询命令
- 停靠取"小组件所在显示器"的工作区（多显示器下贴到常用屏的角落）；
  自由态的漂出召回仍以主屏工作区为准
- `glmu_widget.ps1` 必须保存为 **UTF-8 with BOM**（PowerShell 5.1 中文兼容），
  修改本文件时注意保留 BOM

## 许可证

[MIT](LICENSE)
