# glmu 安卓锁屏小组件 — 方案计划（暂缓）

> **状态**：调研完成、方案 A 方向已确认，实施暂缓（2026-10-27 用户决策）。
> **目标设备**：荣耀 Magic 8 Pro / MagicOS 10.0.0.170（国行）。
> **恢复推进时**：直接从 [第 5 节 动工前置条件](#5-动工前置条件恢复时从这里开始) 开始，不需要重新调研。

## 1. 背景与目标

GLM Coding Plan 用量目前在 Windows 桌面悬浮组件（`windows/glmu_widget.ps1`，经 WSL 调用 `glm_usage_all.py` 取数）展示。目标：在**安卓手机锁屏页面**以原生小组件形态展示同样的用量信息（多订阅、5 小时窗口/周额度、绿/黄/红阈值着色）。

约束：
- API Key 只存设备本地，不经过任何中间服务、不下发公网
- 复用现有查询接口（`open.bigmodel.cn` 只读监控接口）与视觉语义，不新造数据链路

## 2. 调研结论（2026-10-26）

### 2.1 安卓锁屏能力现状

| 事实 | 来源 |
|------|------|
| Android 16 QPR2（2025-12 stable）起 Pixel 手机回归锁屏小组件（锁屏右滑面板），此前仅平板；三星 One UI 锁屏 widget 列表很受限，第三方基本进不去 | Android Authority、Reddit r/androidapps（调研快照） |
| **荣耀 MagicOS 10 于 2026 年 4 月上线锁屏小组件，Magic8 系列为首批机型**（需 ≥ 10.0.0.150；7 月版支持组件自由摆放；生态 60 款组件、55 场景，声称安卓阵营首位） | 荣耀俱乐部公告、IT之家、中国日报网（调研快照） |
| **荣耀锁屏小组件基于标准 Android AppWidget 机制实现**（非私有 SDK），接入文档在荣耀开发者服务平台 lockscreen 专区 | [接入指南](https://developer.honor.com/cn/docs/lockscreen/guides/integration)、[产品介绍](https://developer.honor.com/cn/docs/lockscreen/guides/introduction) |
| 添加路径：锁屏长按 → 自定义锁屏 → +添加小组件（现有步数、耳机电量、世界时钟、京东等；**无通用 HTTP/文本/GLM 相关组件，已实测确认不可零开发复用**） | 荣耀官方支持文档 + 本机实测（2026-10-26） |
| 荣耀"灵动胶囊"（灵动岛类）锁屏态仅对已适配 App 弹横幅通知，完整锁屏胶囊形态未实现 | 荣耀官方支持页、荣耀俱乐部需求贴（调研快照） |
| GLM 用量无现成安卓 App/组件（官方仅 Claude Code CLI 插件；搜到的 Widget 教程是 iOS 的） | docs.bigmodel.cn、社区搜索（调研快照） |

### 2.2 本机实测（WSL，2026-10-26）

| 测试 | 结果 | 结论 |
|------|------|------|
| `curl https://open.bigmodel.cn/api/monitor/usage/quota/limit` | **200 OK，110ms** | 手机本地直连查询可行，无需中间服务 |
| `curl https://ntfy.sh/v1/health`（8s 超时） | **超时，0 字节** | 境外推送通道直连不通，PC 推送方案（ntfy.sh 公共实例）排除 |

### 2.3 数据源（复用点）

- 端点：`https://open.bigmodel.cn/api/monitor/usage/quota/limit`，认证用 `ANTHROPIC_API_KEY`（GLM Coding Plan 订阅 Key），详见 `glm_usage_query.py`
- 多订阅聚合逻辑与 JSON 输出：`glm_usage_all.py`（`--json` 供程序调用）
- 只读监控接口，无扣费/配置变更能力（README 安全说明）

## 3. 方案对比与选型

| 方案 | 说明 | 结论 |
|------|------|------|
| **A. 自研原生小 App（选定）** | Kotlin + 标准 AppWidget + WorkManager 定时查询；荣耀锁屏组件基于标准 AppWidget 机制 | ✅ 唯一字面满足"锁屏组件"的路线，桌面+锁屏双收益 |
| B. MacroDroid/Tasker 常驻通知 | 零代码；锁屏以通知卡片显示（非组件位）；key 明文存自动化 App；需按荣耀保活路径配置（系统管家 → 应用启动管理 → 关自动管理 + 允许后台活动；电池优化"不允许"） | 备选 / A 交付前的快速过渡 |
| C. 通用 HTTP 组件 App 复用 | 锁屏组件列表实测无可用通用组件 | ❌ 已排除 |
| D. PC 定时查询 + 推送（ntfy 常驻通知，`X-Sequence-ID` 支持原地更新） | ntfy.sh 实测直连超时，需自建 + 内网穿透，依赖 PC 常开 | ❌ 已排除 |

**选型**：方案 A。理由：目标机型技术底座就位（MagicOS 10 原生锁屏组件 + 标准 AppWidget 机制 + API 境内直连实测通过）；一次性投入换来形态完全匹配。

## 4. 选定方案 A 蓝图

### 4.1 架构

新增 `android/` 独立工程（不改动仓库现有 Python 脚本与 Windows 组件），三部分：

1. **配置页（ConfigActivity）**：首启动录入多个订阅 Key（对齐 Windows 侧多 Profile 总览），`EncryptedSharedPreferences` 存应用私有目录
2. **组件（AppWidgetProvider + RemoteViews）**：多订阅各一行百分比（5h 窗口优先），按已用阈值着色（<60% 绿、60%~85% 黄、≥85% 红，对齐 Windows 版语义）
3. **刷新（WorkManager 周期任务）**：默认 30 分钟（Android 周期任务下限 15 分钟）；点按组件手动刷新兜底

### 4.2 数据流

`App（手机本地）→ GET open.bigmodel.cn/api/monitor/usage/quota/limit（带 Key）→ 解析 → RemoteViews 渲染 → 桌面/锁屏组件更新`。不经任何中间服务，key 不出手机。

### 4.3 错误处理

- 查询失败：组件标 ✗，保留上次成功值与更新时间
- 未配置 Key：组件显示"点此配置"，点击进配置页

### 4.4 测试

- 解析/着色/渲染逻辑：JVM 单测（可复用 `glm_usage_all.py --json` 的输出样例做固定用例）
- 真机侧载后验证两点：锁屏"添加小组件"列表是否收录；刷新与着色符合预期

### 4.5 风险与缓解

| 风险 | 等级 | 缓解 |
|------|------|------|
| 荣耀锁屏"添加小组件"列表**不收录第三方直装 App**（60 款生态规模暗示可能有适配/收录流程） | 高（最大风险） | 动工前精读[接入指南](https://developer.honor.com/cn/docs/lockscreen/guides/integration)确认收录规则；若最终不收录，降级为桌面组件（仍有价值）+ MacroDroid 通知补位锁屏 |
| WorkManager 周期下限 15 分钟，无法对齐 Windows 组件的 60 秒刷新 | 低 | 锁屏场景接受分钟级；点按手动刷新兜底 |
| WSL 构建链搭建（JDK17 + Android cmdline-tools，一次性 ~1-2GB） | 低 | 一次性成本；构建 APK 后用户侧载 |

### 4.6 影响面

- 新增 `android/` 目录（App 工程）；不修改现有文件行为
- WSL 安装 JDK17 + Android cmdline-tools（构建环境）
- API Key 仅存手机应用私有目录（只读监控 Key，无扣费能力）

## 5. 动工前置条件（恢复时从这里开始）

1. **精读荣耀锁屏组件接入文档**（[接入指南](https://developer.honor.com/cn/docs/lockscreen/guides/integration)、[产品介绍](https://developer.honor.com/cn/docs/lockscreen/guides/introduction)），确认：锁屏列表收录条件、是否有 meta-data/尺寸要求、是否需开发者平台注册 —— **此结论直接决定方案 A 是否成立，放在一切开发工作之前**
2. 确认用户手机仍为系统自带锁屏（荣耀锁屏组件仅在系统锁屏生效，第三方锁屏 App 上不显示）
3. WSL 搭建构建链：JDK17 + Android cmdline-tools + Gradle
4. 按仓库流程：本计划获用户重新确认 → `/openspec:proposal`（中任务，tasks 拆分）→ TDD 实现 → 侧载验证
5. （可选过渡）方案 B MacroDroid 通知，10 分钟见效，与方案 A 不冲突

## 6. 决策与时间线

| 日期 | 事件 |
|------|------|
| 2026-10-26 | 完成可行性调研（安卓锁屏能力现状 + 荣耀 Magic 8 Pro 特化 + 本机连通性实测）；呈报顶层蓝图，方案 A 方向获用户确认 |
| 2026-10-27 | 蓝图落本文档；**实施暂缓**（用户决策），未创建 OpenSpec 提案、未写任何代码 |

## 附录：参考链接

- 荣耀锁屏小组件接入指南：https://developer.honor.com/cn/docs/lockscreen/guides/integration
- 荣耀锁屏小组件产品介绍：https://developer.honor.com/cn/docs/lockscreen/guides/introduction
- 荣耀锁屏小组件上线公告（荣耀俱乐部）：https://club.honor.com/cn/thread-30124595-1-1.html
- 荣耀灵动胶囊说明：https://www.honor.com/cn/support/content/zh-cn15867850
- ntfy 发送文档（X-Sequence-ID 原地更新通知）：https://docs.ntfy.sh/publish/
- GLM Coding Plan 套餐概览：https://docs.bigmodel.cn/cn/coding-plan/overview
