[中文](README.zh-CN.md) | English

# afk

`afk` is an anti-addiction script for AI coding tools: it tracks daily usage time and, once thresholds are reached, moves through reminder, wrap-up, and blocking stages.

## Demo video

https://github.com/tivnantu/afk/raw/refs/heads/main/assets/afk-demo.mp4

> If the video does not render, open [`assets/afk-demo.mp4`](https://github.com/tivnantu/afk/raw/refs/heads/main/assets/afk-demo.mp4) directly.

## Overview

- Uses hooks to measure actual AI working intervals
- Moves through reminder, wrap-up, and blocking stages once thresholds are reached
- Supports multiple IDEs while sharing one daily usage record
- Sends macOS notifications
- Supports configurable thresholds and manual reset

## Stages and default thresholds

The default thresholds are `8h / 10h / 12h`, and all of them are configurable.

The stage identifiers used below are `green`, `yellow`, `orange`, and `red`, corresponding to: **normal**, **reminder**, **wrap-up**, and **blocking**.

```text
🟢  0h  ──  8h     Normal (green)
🟡  8h  ── 10h     Reminder (yellow)
🟠 10h  ── 12h     Wrap-up (orange)
🔴 12h+            Blocking (red)
```

| Stage | Range | Behavior |
|---|---|---|
| 🟢 **Normal (`green`)** | 0 ~ T1 | No intervention |
| 🟡 **Reminder (`yellow`)** | T1 ~ T2 | Send a macOS notification every 15 minutes |
| 🟠 **Wrap-up (`orange`)** | T2 ~ T3 | Notify and inject a wind-down instruction into AI context |
| 🔴 **Blocking (`red`)** | T3+ | Block new `UserPromptSubmit` requests |

## How it works

`afk` uses interval timing rather than trying to infer activity from mouse, keyboard, or idle-time heuristics.

```text
UserPromptSubmit ────── AI working ────── Stop
  start_time = now                    total += now - start_time
```

The timing rules are:
- **`UserPromptSubmit`**: start the timer and determine the current stage from the accumulated total
- **`Stop`**: close the current interval and persist it
- **`PostToolUse`**: only used to keep notifications flowing during long-running tasks; it does not advance the timer

This has a few practical consequences:
- Long AI runs are counted as one full interval
- Time away from the keyboard, lunch breaks, or other pauses are not counted
- No separate “idle threshold” is needed to guess whether the user is still working

## Supported IDEs

The script currently ships presets for the following targets:

| IDE | `--ide` value |
|---|---|
| Claude Code | `claude` |
| CodeBuddy | `codebuddy` |
| Cursor | `cursor` |
| Cline | `cline` |
| Augment | `augment` |
| Windsurf | `windsurf` |

By default, `afk` installs into **all detected IDEs** so that usage tracking and intervention stay consistent across AI tools.

## Prerequisites

- macOS (notifications depend on `osascript`)
- [`jq`](https://jqlang.org/) (`brew install jq`)

## Quick start

### One-line install

```bash
curl -fsSL https://raw.githubusercontent.com/tivnantu/afk/main/afk.sh -o ~/.local/bin/afk.sh \
  && chmod +x ~/.local/bin/afk.sh \
  && ~/.local/bin/afk.sh install
```

### Or install from the repository

```bash
git clone https://github.com/tivnantu/afk.git && cd afk
./afk.sh install
```

After installation, restart your IDE so the hooks take effect.

## Common commands

```bash
afk.sh status                         # Show today's usage, stage, and hook status
afk.sh set --t1 6 --t2 8 --t3 10     # Change thresholds
afk.sh reset                          # Reset today's timer
afk.sh install                        # Install into all detected IDEs
afk.sh install --ide cursor           # Install into one IDE
afk.sh uninstall                      # Remove hooks and script
afk.sh --help                         # Show help
```

Notes:
- Running `afk.sh set` with no arguments prints the current thresholds
- `afk.sh uninstall` removes the hooks registered in each IDE's `settings.json`; after uninstall, no more wind-down injection or `prompt` blocking will occur
- `afk.sh uninstall` preserves historical data files and does not delete usage records automatically

## Configuration

### Via environment variables

```bash
export AFK_T1=8      # green → yellow
export AFK_T2=10     # yellow → orange
export AFK_T3=12     # orange → red
```

### Or persist the values

```bash
afk.sh set --t1 6 --t2 8 --t3 10
```

Config file location:

```text
~/.local/share/afk/config.json
```

Environment variables take precedence over persisted configuration.

## Intervention behavior

### Notifications

When the current stage is `yellow`, `orange`, or `red`, `afk` sends macOS notifications according to its notification throttle interval.

Each notification has two parts:
- **title**: a short prompt line
- **body**: objective status information, such as elapsed time and the remaining time until the next stage or blocking

### Orange stage

The `orange` stage does not interrupt tools that are already running. Instead, it injects additional context through `UserPromptSubmit` to steer the AI toward:
- finishing the current task first
- avoiding new subtasks or large-scale changes
- keeping responses shorter
- ending with a progress summary and remaining TODOs

The injected content includes the **accumulated usage time for the day**, **the remaining time before `red`**, and the **current stage**, and it uses a two-tier strategy:

- **first half (`ORANGE`)**: tell the AI to wrap up the current task, avoid opening new tasks or large refactors, and append a brief progress summary plus TODOs at the end of the reply
- **second half (`ORANGE-CRITICAL`)**: allow only the current in-flight operation to finish; do not start new tool calls or subtasks, and then produce a short handoff note including what was completed, what remains, and the next step

The goal of `orange` is not to interrupt immediately, but to progressively narrow the output into “finish the current thing, then stop.”

### Red stage

The `red` stage blocks new `UserPromptSubmit` requests, but it does not proactively terminate tool calls that are already in progress.

That means:
- **no new `prompt` can be submitted**
- **tasks that have already started can finish naturally**

## Edge cases

| Scenario | Behavior |
|---|---|
| Lunch break or time away from the keyboard | The previous `Stop` has already ended timing, so that time is not counted |
| AI runs continuously for 45 minutes | The full `prompt → stop` interval is counted |
| IDE crashes mid-task | An orphaned `start_time` is closed defensively on the next `prompt` |
| The session crosses midnight | Daily statistics reset automatically on the new date |
| Multiple IDEs are used at the same time | They share the same `usage.json`, contributing to one daily total |
| `reset` is triggered manually | Daily timing and notification throttle state are reset together |

## File layout

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

- **`assets/afk-demo.mp4`**: demo video
- **`afk.sh`**: main script containing hook, install, status, configuration, and reset logic
- **`test.sh`**: interactive demo script that simulates all stages

After installation, the script also uses the following paths:

```text
~/.local/bin/afk.sh            # installed script
~/.local/share/afk/usage.json  # daily usage data
~/.local/share/afk/config.json # persisted thresholds (optional)
```

Each target IDE's `settings.json` will have these three hooks registered:
- `UserPromptSubmit`
- `Stop`
- `PostToolUse`

## License

[MIT](LICENSE)
