[English](README.md) | 中文

# afk

`afk` 是一个用于 AI 编码工具的防沉迷脚本：统计每日使用时长，并在达到阈值后依次执行提醒、收尾和拦截。

## 演示视频

https://github.com/user-attachments/assets/63483dff-f812-4085-bcf7-6d90df3bb45e

> 如果视频未能直接播放，请打开 [`assets/afk-demo.mp4`](assets/afk-demo.mp4)。

## 功能概览

- 基于 hook 统计 AI 实际工作时段
- 达到阈值后会依次进入提醒、收尾和拦截阶段
- 支持多 IDE，共享同一份每日使用统计
- 支持 macOS 通知提醒
- 支持自定义阈值与手动重置

## 阶段与默认阈值

默认阈值为 `8h / 10h / 12h`，均可配置。

下文保留 `green`、`yellow`、`orange`、`red` 作为阶段标识，分别对应：**正常、提醒、收尾、拦截**。

```text
🟢  0h  ──  8h     正常（green）
🟡  8h  ── 10h     提醒（yellow）
🟠 10h  ── 12h     收尾（orange）
🔴 12h+            拦截（red）
```

| 阶段 | 区间 | 行为 |
|---|---|---|
| 🟢 **正常（green）** | 0 ~ T1 | 不干预 |
| 🟡 **提醒（yellow）** | T1 ~ T2 | 每 15 分钟发送一次 macOS 通知 |
| 🟠 **收尾（orange）** | T2 ~ T3 | 通知提醒，并向 AI 注入“收尾”指令 |
| 🔴 **拦截（red）** | T3+ | 拦截新的 `UserPromptSubmit` 请求 |

## 工作机制

`afk` 使用区间计时，而不是基于鼠标、键盘或空闲时间做推断。

```text
UserPromptSubmit ────── AI 工作中 ────── Stop
  start_time = now                    total += now - start_time
```

计时规则如下：
- **`UserPromptSubmit`**：开始计时，并根据当前累计时长判断阶段
- **`Stop`**：结束当前区间并持久化
- **`PostToolUse`**：仅用于长任务期间补发通知，不推进计时器

这种方式的特点是：
- AI 长时间执行任务时，整段区间会被计入
- 用户离开、吃饭或暂停使用时，不会被误计入
- 不需要额外定义“空闲阈值”来猜测用户是否仍在工作

## 支持的 IDE

当前内置以下目标：

| IDE | `--ide` 值 |
|---|---|
| Claude Code | `claude` |
| CodeBuddy | `codebuddy` |
| Cursor | `cursor` |
| Cline | `cline` |
| Augment | `augment` |
| Windsurf | `windsurf` |

默认会安装到**所有检测到的 IDE**，以确保统计和干预行为在不同 AI 工具之间保持一致。

## 前置条件

- macOS（通知依赖 `osascript`）
- [`jq`](https://jqlang.org/)（`brew install jq`）

## 快速开始

### 一行安装

```bash
curl -fsSL https://raw.githubusercontent.com/tivnantu/afk/main/afk.sh -o ~/.local/bin/afk.sh \
  && chmod +x ~/.local/bin/afk.sh \
  && ~/.local/bin/afk.sh install
```

### 或者从仓库安装

```bash
git clone https://github.com/tivnantu/afk.git && cd afk
./afk.sh install
```

安装完成后，重启 IDE 使 hook 生效。

## 常用命令

```bash
afk.sh status                         # 查看今日使用时长、阶段和 hook 状态
afk.sh set --t1 6 --t2 8 --t3 10     # 修改阈值
afk.sh reset                          # 重置当日计时
afk.sh install                        # 安装到所有检测到的 IDE
afk.sh install --ide cursor           # 安装到指定 IDE
afk.sh uninstall                      # 卸载 hook 和脚本
afk.sh --help                         # 查看帮助
```

补充说明：
- `afk.sh set` 不带参数时，会打印当前阈值
- `afk.sh uninstall` 会移除各 IDE `settings.json` 中注册的 hook；卸载后不再注入收尾指令，也不会继续拦截 `prompt`
- `afk.sh uninstall` 会保留历史数据文件，不会自动删除使用记录

## 配置

### 通过环境变量设置

```bash
export AFK_T1=8      # green → yellow
export AFK_T2=10     # yellow → orange
export AFK_T3=12     # orange → red
```

### 通过命令持久化保存

```bash
afk.sh set --t1 6 --t2 8 --t3 10
```

配置文件位置：

```text
~/.local/share/afk/config.json
```

环境变量优先级高于持久化配置。

## 干预行为说明

### 通知

当阶段为 `yellow`、`orange` 或 `red` 时，`afk` 会按通知节流间隔发送 macOS 通知。

通知分为两部分：
- **title**：简短提示语
- **body**：客观状态信息，例如已用时长与距下一阶段/距拦截的剩余时间

### Orange 阶段

`orange` 阶段不会中断已经开始执行的工具调用，而是通过 `UserPromptSubmit` 注入额外上下文，引导 AI：
- 优先完成当前任务
- 避免开启新的子任务或大规模改动
- 使用更简洁的回复
- 以进度总结和待办项收尾

注入内容会带上**当日累计使用时长**、**距离 `red` 还剩多久**以及**当前阶段**，并采用两档策略：

- **前半段（ORANGE）**：要求 AI 收尾当前任务，避免开启新任务或大改动，并在回复末尾附上简短进度总结与待办事项。
- **后半段（ORANGE-CRITICAL）**：只允许完成当前正在进行的操作，不再启动新的工具调用或子任务；完成后输出简短交接说明，包括已完成内容、剩余工作和下一步建议。

`orange` 的目标不是立刻打断，而是把后续输出逐步收缩到“做完当前这点事，然后停”。

### Red 阶段

`red` 阶段拦截的是新的 `UserPromptSubmit`，不会主动终止已经在执行中的工具调用。

这意味着：
- **不能再发起新的 `prompt`**
- **已经开始的任务可以自然结束**

## 边界场景

| 场景 | 行为 |
|---|---|
| 午饭或离开电脑一段时间 | 上一个 `Stop` 已经结束计时，离开时间不会计入 |
| AI 连续执行 45 分钟 | 整段 `prompt → stop` 区间计入 |
| IDE 中途崩溃 | 遗留的 `start_time` 会在下一次 `prompt` 时防御性闭合 |
| 跨过午夜 | 新的一天会自动重置日统计 |
| 多个 IDE 同时使用 | 共享同一份 `usage.json`，累计到同一日总时长 |
| 手动执行 `reset` | 当日计时与通知节流状态一并重置 |

## 文件结构

```text
afk/
├── assets/
│   └── afk-demo.mp4
├── afk.sh
├── test.sh
├── README.md
├── README.zh-CN.md
├── .gitignore
└── LICENSE
```

- **`assets/afk-demo.mp4`**：演示视频
- **`afk.sh`**：主脚本，包含 hook、安装、状态、配置和重置逻辑
- **`test.sh`**：交互式演示脚本，用于模拟各阶段行为

安装后还会使用以下路径：

```text
~/.local/bin/afk.sh            # 安装后的脚本
~/.local/share/afk/usage.json  # 每日使用数据
~/.local/share/afk/config.json # 持久化阈值（可选）
```

各目标 IDE 的 `settings.json` 中会注册以下 3 个 hook：
- `UserPromptSubmit`
- `Stop`
- `PostToolUse`

## License

[MIT](LICENSE)
