#!/bin/bash
# afk test script — 演示四个阶段 + 连续弹通知看随机效果
# 通过预注入 usage.json 模拟真实时长
#
# Usage: bash test.sh

set -euo pipefail

AFK="$(cd "$(dirname "$0")" && pwd)/afk.sh"
DATA_DIR="${HOME}/.local/share/afk"
DATA_FILE="${DATA_DIR}/usage.json"
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[32m'
YELLOW='\033[33m'
ORANGE='\033[38;5;208m'
RED='\033[31m'
CYAN='\033[36m'
RESET='\033[0m'

step=0
_step() {
    step=$((step + 1))
    echo ""
    echo -e "${BOLD}${CYAN}━━━ Step ${step}: $1 ━━━${RESET}"
    echo ""
    sleep 1
}

_run() {
    echo -e "  ${DIM}\$ $1${RESET}"
    eval "$1" 2>&1 | sed 's/^/  /'
    echo ""
    sleep 1
}

_pause() {
    echo -e "  ${DIM}(${1:-按 Enter 继续...})${RESET}"
    read -r
}

_inject_usage() {
    local total="$1"
    local today
    today=$(date +%Y-%m-%d)
    mkdir -p "$DATA_DIR"
    cat > "$DATA_FILE" <<EOF
{
  "date": "${today}",
  "total_seconds": ${total},
  "start_time": 0,
  "last_notify": 0,
  "sessions": $((total / 1800))
}
EOF
}

# ─── Backup & restore ────────────────────────────────────────────────────────
#
# Tests mutate both usage.json (forced timings) and config.json (via `afk set`).
# Back both up so user state is fully preserved when the test script exits.

_backup_usage=""
_backup_config=""
if [ -f "$DATA_FILE" ]; then
    _backup_usage="${DATA_FILE}.bak.$$"
    cp "$DATA_FILE" "$_backup_usage"
fi
if [ -f "${DATA_DIR}/config.json" ]; then
    _backup_config="${DATA_DIR}/config.json.bak.$$"
    cp "${DATA_DIR}/config.json" "$_backup_config"
fi

_cleanup() {
    # Restore usage.json
    if [ -n "$_backup_usage" ] && [ -f "$_backup_usage" ]; then
        mv "$_backup_usage" "$DATA_FILE"
    else
        rm -f "$DATA_FILE"
    fi
    # Restore config.json (only drop it if the user had none before the test)
    if [ -n "$_backup_config" ] && [ -f "$_backup_config" ]; then
        mv "$_backup_config" "${DATA_DIR}/config.json"
    else
        rm -f "${DATA_DIR}/config.json"
    fi
}
trap _cleanup EXIT

# ─── Start ────────────────────────────────────────────────────────────────────

clear
echo -e "${BOLD}🎮 afk — AI 防沉迷机制 测试${RESET}"
echo -e "${DIM}Anti-addiction system for AI coding tools${RESET}"
echo ""
_pause "按 Enter 开始测试"

# ─── 1. Fresh start ──────────────────────────────────────────────────────────

_step "查看初始状态"
_inject_usage 0
_run "bash $AFK status"
_pause

# ─── 2. Green: normal ────────────────────────────────────────────────────────

_step "🟢 green — 正常工作 (2 时 15 分)"
_inject_usage 8100
echo -e "  ${GREEN}已工作 2 时 15 分, prompt 正常放行${RESET}"
echo ""
_run "echo '{}' | bash $AFK prompt"
sleep 2
_run "echo '{}' | bash $AFK stop"
_run "bash $AFK status"
_pause

# ─── 3. Yellow: single notification ──────────────────────────────────────────

_step "🟡 yellow — 单条通知 (8 时 32 分)"
_inject_usage 30720
echo -e "  ${YELLOW}已工作 8 时 32 分, 进入 yellow, 弹出通知${RESET}"
echo ""
_run "echo '{}' | bash $AFK prompt"
_run "echo '{}' | bash $AFK stop"
_pause

# ─── 4. Yellow: burst notifications ──────────────────────────────────────────

_step "🟡 yellow — 连续 5 条通知 (看随机效果)"
echo -e "  ${YELLOW}每条通知的 body 都是随机从 10 条候选中选的${RESET}"
echo ""
for i in 1 2 3 4 5; do
    # _inject_usage resets last_notify to 0, bypassing the 15-min throttle.
    _inject_usage 30720
    echo -e "  ${DIM}[$i/5]${RESET}"
    echo '{}' | bash "$AFK" prompt >/dev/null 2>&1 || true
    echo '{}' | bash "$AFK" stop >/dev/null 2>&1 || true
    sleep 2
done
echo -e "  ${YELLOW}👆 检查通知中心, 5 条通知各不相同${RESET}"
_pause

# ─── 5. Orange: inject ───────────────────────────────────────────────────────

_step "🟠 orange — 注入收束指令 (10 时 45 分)"
_inject_usage 38700
echo -e "  ${ORANGE}已工作 10 时 45 分, 进入 orange, 注入收束指令${RESET}"
echo ""
_run "echo '{}' | bash $AFK prompt"
_run "echo '{}' | bash $AFK stop"
_pause

# ─── 6. Orange: burst notifications ──────────────────────────────────────────

_step "🟠 orange — 连续 5 条通知"
echo -e "  ${ORANGE}语气比 yellow 更重, 看看区别${RESET}"
echo ""
for i in 1 2 3 4 5; do
    cur_total=$((38700 + i * 900))  # 10h45m + 递增
    _inject_usage $cur_total
    echo -e "  ${DIM}[$i/5]${RESET}"
    echo '{}' | bash "$AFK" prompt >/dev/null 2>&1 || true
    echo '{}' | bash "$AFK" stop >/dev/null 2>&1 || true
    sleep 2
done
echo -e "  ${ORANGE}👆 检查通知中心, 语气明显更重了${RESET}"
_pause

# ─── 7. Orange critical ──────────────────────────────────────────────────────

_step "🟠 orange 后期 — 加重收束 (11 时 30 分)"
_inject_usage 41400
echo -e "  ${ORANGE}接近 T3, 收束指令变为 ORANGE-CRITICAL${RESET}"
echo ""
_run "echo '{}' | bash $AFK prompt"
_run "echo '{}' | bash $AFK stop"
_pause

# ─── 8. Red: blocked ─────────────────────────────────────────────────────────

_step "🔴 red — 拒绝 prompt (12 时 17 分)"
_inject_usage 44220
echo -e "  ${RED}已工作 12 时 17 分, prompt 被拦截${RESET}"
echo ""
echo -e "  ${DIM}\$ echo '{}' | bash $AFK prompt${RESET}"
echo '{}' | bash "$AFK" prompt 2>&1 | sed 's/^/  /' || true
echo ""
echo -e "  ${RED}👆 exit code 2, 用户看到 stderr 提示${RESET}"
_pause

# ─── 9. Red: burst notifications ─────────────────────────────────────────────

_step "🔴 red — 连续 5 条通知"
echo -e "  ${RED}最重的语气, 每条都不一样${RESET}"
echo ""
for i in 1 2 3 4 5; do
    cur_total=$((44220 + i * 600))  # 12h17m + 递增
    _inject_usage $cur_total
    echo -e "  ${DIM}[$i/5]${RESET}"
    echo '{}' | bash "$AFK" prompt 2>/dev/null || true
    sleep 2
done
echo -e "  ${RED}👆 检查通知中心, 又气又无奈${RESET}"
_pause

# ─── 10. PostToolUse in long task ─────────────────────────────────────────────

_step "长任务 PostToolUse — 只通知, 不推进计时"
_inject_usage 33000
echo -e "  ${YELLOW}模拟: AI 跑长任务 (9 时 10 分), 期间只靠 PostToolUse 发通知${RESET}"
echo -e "  ${DIM}重点: PostToolUse 刻意不推进 timer, 避免与 UserPromptSubmit→Stop 双写${RESET}"
echo ""
_run "echo '{}' | bash $AFK prompt"
echo -e "  ${DIM}--- 开始跑长任务, 打印当前 total_seconds ---${RESET}"
_run "jq '{total_seconds, start_time}' $DATA_FILE"
echo -e "  ${DIM}(假装) AI 运行中, 触发 3 次 PostToolUse...${RESET}"
for i in 1 2 3; do
    echo '{}' | bash "$AFK" post-tool >/dev/null 2>&1 || true
    sleep 1
done
echo -e "  ${DIM}--- 3 次 PostToolUse 后, total_seconds 是否有变化? ---${RESET}"
_run "jq '{total_seconds, start_time}' $DATA_FILE"
echo -e "  ${DIM}👆 total_seconds 应保持 33000 不变, start_time 也不动${RESET}"
echo ""
_run "echo '{}' | bash $AFK stop"
echo -e "  ${DIM}--- Stop 后, total_seconds 被 UserPromptSubmit→Stop 区间累加 ---${RESET}"
_run "jq '{total_seconds, start_time}' $DATA_FILE"
_pause

# ─── 11. Custom thresholds ───────────────────────────────────────────────────

_step "自定义阈值"
_run "bash $AFK set --t1 6 --t2 8 --t3 10"
_run "bash $AFK status"
_pause

# ─── 12. Reset ────────────────────────────────────────────────────────────────

_step "重置"
_run "bash $AFK reset"
_run "bash $AFK status"

# ─── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${CYAN}━━━ 测试结束 ━━━${RESET}"
echo ""
echo -e "  安装: ${BOLD}bash afk.sh install${RESET}"
echo -e "  状态: ${BOLD}bash afk.sh status${RESET}"
echo -e "  帮助: ${BOLD}bash afk.sh --help${RESET}"
echo ""
