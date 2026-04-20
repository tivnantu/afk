#!/bin/bash
# afk — AI anti-addiction system (Away From Keyboard)
#
# Track daily AI usage time. Escalate automatically when you've been using AI too long:
#   🟢 green  (0~T1)   — normal, no intervention
#   🟡 yellow (T1~T2)  — macOS notification reminders
#   🟠 orange (T2~T3)  — inject wind-down prompt into AI context
#   🔴 red    (T3+)    — block all new prompts
#
# Core hooks (timer):
#   UserPromptSubmit — start timer + notify/inject/block
#   Stop             — stop timer + persist
#
# Auxiliary hook (long-task coverage):
#   PostToolUse      — notify only (no timer, no inject, no block)
#
# Usage:
#   afk.sh prompt           Hook mode: UserPromptSubmit
#   afk.sh stop             Hook mode: Stop
#   afk.sh post-tool        Hook mode: PostToolUse (notify during long tasks)
#   afk.sh status           Show today's usage and current stage
#   afk.sh set [options]    Adjust thresholds
#   afk.sh reset            Reset today's timer
#   afk.sh install          Install hooks into detected IDEs
#   afk.sh uninstall        Remove hooks and script

set -euo pipefail

# ─── Config ───────────────────────────────────────────────────────────────────

T1="${AFK_T1:-8}"                                  # green → yellow (hours)
T2="${AFK_T2:-10}"                                 # yellow → orange
T3="${AFK_T3:-12}"                                 # orange → red
# Env-var inputs are sanitized below so a typo like AFK_T1=eight can't wedge
# hooks under `set -euo pipefail` via arithmetic failure.
case "$T1" in ''|*[!0-9]*|0) T1=8  ;; esac
case "$T2" in ''|*[!0-9]*|0) T2=10 ;; esac
case "$T3" in ''|*[!0-9]*|0) T3=12 ;; esac
NOTIFY_INTERVAL=900                                # 15 min between notifications

DATA_DIR="${HOME}/.local/share/afk"
DATA_FILE="${DATA_DIR}/usage.json"
CONF_FILE="${DATA_DIR}/config.json"
INSTALL_DIR="${HOME}/.local/bin"
INSTALL_PATH="${INSTALL_DIR}/afk.sh"
HOOK_CMD="${HOME}/.local/bin/afk.sh"
HOOK_TAG="# managed by afk"

# IDE definitions: name:config_dir
_IDES=(
    "claude:$HOME/.claude"
    "codebuddy:$HOME/.codebuddy"
    "cursor:$HOME/.cursor"
    "cline:$HOME/.cline"
    "augment:$HOME/.augment"
    "windsurf:$HOME/.windsurf"
)

# ─── Prerequisites ────────────────────────────────────────────────────────────

_require() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "❌ '$1' is required but not found. Install it first." >&2
        exit 1
    }
}

# ─── IDE helpers ──────────────────────────────────────────────────────────────

_ide_name()     { echo "${1%%:*}"; }
_ide_dir()      { echo "${1#*:}"; }
_ide_settings() { echo "${1#*:}/settings.json"; }

_get_ide() {
    for ide in "${_IDES[@]}"; do
        if [ "$(_ide_name "$ide")" = "$1" ]; then
            echo "$ide"
            return 0
        fi
    done
    return 1
}

_resolve_ides() {
    # Resolve target IDEs: --ide <name> → single IDE, else ALL detected IDEs.
    # Unlike sip/hotfiles which pick the first match, afk installs to ALL
    # because anti-addiction should cover every AI tool on the machine.
    local explicit_ide=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --ide) shift
                   explicit_ide="${1:-}"
                   [ -z "$explicit_ide" ] && { echo "❌ --ide requires a value" >&2; exit 1; }
                   shift ;;
            *) shift ;;
        esac
    done

    if [ -n "$explicit_ide" ]; then
        local entry
        if ! entry=$(_get_ide "$explicit_ide"); then
            echo "❌ unknown IDE: $explicit_ide (supported: $(for i in "${_IDES[@]}"; do _ide_name "$i"; done | tr '\n' ' '))" >&2
            exit 1
        fi
        echo "$entry"
    else
        # Install to ALL IDEs whose config dir exists (or create for claude as fallback)
        local found=0
        for ide in "${_IDES[@]}"; do
            if [ -d "$(_ide_dir "$ide")" ]; then
                echo "$ide"
                found=1
            fi
        done
        # fallback: at least claude
        if [ "$found" -eq 0 ]; then
            echo "claude:$HOME/.claude"
        fi
    fi
}

_scan_ides() {
    for ide in "${_IDES[@]}"; do
        echo "$ide"
    done
}

# ─── Data helpers ─────────────────────────────────────────────────────────────

_ensure_data_dir() {
    mkdir -p "$DATA_DIR"
}

_load_config() {
    # Load persistent config (thresholds set via `afk.sh set`).
    # Environment variables take precedence over config.json.
    # Values are validated as positive integers; anything else is silently
    # ignored so a corrupted config.json can't poison T* and wedge hooks
    # under `set -euo pipefail`.
    if [ -f "$CONF_FILE" ]; then
        local ct1 ct2 ct3
        ct1=$(jq -r '.t1 // empty' "$CONF_FILE" 2>/dev/null || true)
        ct2=$(jq -r '.t2 // empty' "$CONF_FILE" 2>/dev/null || true)
        ct3=$(jq -r '.t3 // empty' "$CONF_FILE" 2>/dev/null || true)
        # Only apply config.json value if the env var was NOT set
        [ -z "${AFK_T1:-}" ] && case "$ct1" in ''|*[!0-9]*|0) ;; *) T1="$ct1" ;; esac
        [ -z "${AFK_T2:-}" ] && case "$ct2" in ''|*[!0-9]*|0) ;; *) T2="$ct2" ;; esac
        [ -z "${AFK_T3:-}" ] && case "$ct3" in ''|*[!0-9]*|0) ;; *) T3="$ct3" ;; esac
    fi
}

_now_epoch() {
    date +%s
}

_today() {
    date +%Y-%m-%d
}

_read_data() {
    # Outputs: date total_seconds start_time last_notify sessions
    if [ -f "$DATA_FILE" ]; then
        jq -r '[.date // "", .total_seconds // 0, .start_time // 0, .last_notify // 0, .sessions // 0] | @tsv' "$DATA_FILE" 2>/dev/null || echo "	0	0	0	0"
    else
        echo "	0	0	0	0"
    fi
}

_sanitize_int() {
    # Echo $1 if it is a non-negative integer, else echo 0.
    # Placed before _write_data / _load_state because both call it.
    case "$1" in
        ''|*[!0-9]*) echo 0 ;;
        *)           echo "$1" ;;
    esac
}

_write_data() {
    local date="$1" total="$2" start="$3" last_notify="$4" sessions="$5"
    # Defense in depth: guarantee all numeric fields are actually numbers,
    # otherwise a bad value would produce invalid JSON that poisons the file.
    total=$(_sanitize_int "$total")
    start=$(_sanitize_int "$start")
    last_notify=$(_sanitize_int "$last_notify")
    sessions=$(_sanitize_int "$sessions")
    _ensure_data_dir
    # Use flock for lightweight mutual exclusion so concurrent hooks from
    # multiple IDEs don't clobber each other's writes.
    (
        flock 9 2>/dev/null || true   # best-effort; no flock on some FS
        cat > "$DATA_FILE" <<EOF
{
  "date": "$date",
  "total_seconds": $total,
  "start_time": $start,
  "last_notify": $last_notify,
  "sessions": $sessions
}
EOF
    ) 9>"${DATA_FILE}.lock"
    rm -f "${DATA_FILE}.lock"
}

_load_state() {
    # Load state, auto-reset if new day. All numeric fields are sanitized
    # so a corrupted usage.json can't poison subsequent hook runs.
    local raw today
    raw=$(_read_data)
    today=$(_today)

    d_date=$(echo "$raw" | cut -f1)
    d_total=$(_sanitize_int "$(echo "$raw" | cut -f2)")
    d_start=$(_sanitize_int "$(echo "$raw" | cut -f3)")
    d_notify=$(_sanitize_int "$(echo "$raw" | cut -f4)")
    d_sessions=$(_sanitize_int "$(echo "$raw" | cut -f5)")

    if [ "$d_date" != "$today" ]; then
        d_date="$today"
        d_total=0
        d_start=0
        d_notify=0
        d_sessions=0
    fi
}

_current_total() {
    # Return current total including any in-flight interval
    local total="$d_total"
    if [ "$d_start" -gt 0 ]; then
        local now
        now=$(_now_epoch)
        total=$((total + now - d_start))
    fi
    echo "$total"
}

_stage() {
    # Determine stage from total seconds
    local total="$1"
    local t1_sec=$((T1 * 3600))
    local t2_sec=$((T2 * 3600))
    local t3_sec=$((T3 * 3600))

    if [ "$total" -ge "$t3_sec" ]; then
        echo "red"
    elif [ "$total" -ge "$t2_sec" ]; then
        echo "orange"
    elif [ "$total" -ge "$t1_sec" ]; then
        echo "yellow"
    else
        echo "green"
    fi
}

_format_duration() {
    local secs="$1"
    local h=$((secs / 3600))
    local m=$(( (secs % 3600) / 60 ))
    echo "${h}h${m}m"
}

# ─── Locale detection ─────────────────────────────────────────────────────────

_is_zh() {
    # Check if system language is Chinese
    local lang
    lang=$(defaults read -g AppleLocale 2>/dev/null || echo "en_US")
    case "$lang" in
        zh_*|zh-*) return 0 ;;
        *) return 1 ;;
    esac
}

# ─── Notification messages ────────────────────────────────────────────────────
#
# Layout:
#   title  = random tip (bold, eye-catching — the emotional hook)
#   body   = objective status (elapsed time, remaining time, stage)
#
# The user glances at a notification banner and sees the tip first (title is
# bold and prominent on macOS). The body provides context at a glance.
#
# Tone escalation (10 tips per stage, per language):
#   yellow → lighthearted, playful. "Hey, you've been at it a while."
#   orange → urgent, half-joking threats. "I'm about to pull the plug."
#   red    → dramatic resignation. "It's over. Go to bed."

_random_pick() {
    # Pick a random element from arguments. Safe for any payload (no eval).
    # IMPORTANT: reads /dev/urandom instead of $RANDOM because $RANDOM resets
    # its seed in subshells created by $(...), so consecutive calls within the
    # same second would always return the same index — meaning the user sees
    # the same tip over and over.
    local arr=("$@")
    local n=${#arr[@]}
    [ "$n" -eq 0 ] && return 1
    local r
    r=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null) || r=$$
    local idx=$(( r % n ))
    printf '%s' "${arr[$idx]}"
}

_notify_title_zh() {
    local stage="$1"
    case "$stage" in
        yellow) _random_pick \
            "休息一下吧 ☕" \
            "该站起来了 🧍" \
            "眼睛要罢工了 👀" \
            "喝口水 碳基生物 💧" \
            "伸个懒腰吧 🙆" \
            "你的颈椎在呼救 🦒" \
            "窗外还有个世界 🌤" \
            "深呼吸一下 🧘" \
            "摸一下猫再回来 🐱" \
            "别忘了你还有腰 💆" ;;
        orange) _random_pick \
            "认真的 该收工了 🚨" \
            "再不停我就动手了 🚫" \
            "代码明天还在 你不一定 ⚠️" \
            "你的脊椎发来求救信号 🆘" \
            "键盘快被你焐热了 🔥" \
            "月亮都下班了 🌙" \
            "倒计时开始了 ⏳" \
            "我快拦不住自己了 🤖" \
            "家人等你回去呢 📱" \
            "最后的警告 ⚡" ;;
        red) _random_pick \
            "今天到此为止 🔴" \
            "好了 明天见 👋" \
            "你的 prompt 被我吃了 🙅" \
            "关电脑 睡觉 不许偷写 😴" \
            "游戏结束 请投币 🕹️" \
            "我替你做了决定: 下班 🏠" \
            "reset 可以解封 但你忍心吗 🥺" \
            "电脑也累了 放过它 💻" \
            "你还在? 真的假的 😱" \
            "防沉迷系统已介入 🛡️" ;;
    esac
}

_notify_title_en() {
    local stage="$1"
    case "$stage" in
        yellow) _random_pick \
            "Take a break ☕" \
            "Time to stand up 🧍" \
            "Your eyes need a break 👀" \
            "Hydrate, human 💧" \
            "Big stretch 🙆" \
            "Your neck is not okay 🦒" \
            "There's a world outside 🌤" \
            "Breathe 🧘" \
            "Pet the cat, then come back 🐱" \
            "Remember your spine? 💆" ;;
        orange) _random_pick \
            "Seriously, wrap it up 🚨" \
            "I will block you 🚫" \
            "Code stays. You might not ⚠️" \
            "Your spine sent an SOS 🆘" \
            "Keyboard's overheating 🔥" \
            "Moon clocked out already 🌙" \
            "Countdown started ⏳" \
            "I can barely hold back 🤖" \
            "Someone's waiting for you 📱" \
            "Final warning ⚡" ;;
        red) _random_pick \
            "That's it for today 🔴" \
            "Okay, see you tomorrow 👋" \
            "I ate your prompt 🙅" \
            "Shut it down. Sleep. No cheating 😴" \
            "Game over. Insert coin 🕹️" \
            "Decision made for you: go home 🏠" \
            "reset works, but can you live with it? 🥺" \
            "Even this computer is tired 💻" \
            "Still here? Really? 😱" \
            "Anti-addiction engaged 🛡️" ;;
    esac
}

_notify_body_zh() {
    local stage="$1" elapsed="$2" remain="$3"
    case "$stage" in
        yellow) echo "已用 ${elapsed} · 距下一阶段 ${remain}" ;;
        orange) echo "已用 ${elapsed} · 距强制下线 ${remain}" ;;
        red)    echo "已用 ${elapsed} · 新 prompt 已拦截" ;;
    esac
}

_notify_body_en() {
    local stage="$1" elapsed="$2" remain="$3"
    case "$stage" in
        yellow) echo "Elapsed ${elapsed} · next stage in ${remain}" ;;
        orange) echo "Elapsed ${elapsed} · lockout in ${remain}" ;;
        red)    echo "Elapsed ${elapsed} · new prompts blocked" ;;
    esac
}

# ─── Notification ─────────────────────────────────────────────────────────────

_should_notify() {
    local now
    now=$(_now_epoch)
    [ $((now - d_notify)) -ge "$NOTIFY_INTERVAL" ]
}

_escape_osa() {
    # Escape a string for safe embedding in an AppleScript double-quoted string.
    # Handles backslashes, double quotes, and newlines (AppleScript uses \n
    # for line breaks inside double-quoted strings).
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

_send_notify() {
    local total="$1" stage="$2"
    local h m rh rm t_next
    h=$((total / 3600))
    m=$(( (total % 3600) / 60 ))

    # Compute remaining time to next stage (only meaningful for yellow/orange)
    case "$stage" in
        yellow) t_next=$((T2 * 3600 - total)) ;;
        orange) t_next=$((T3 * 3600 - total)) ;;
        *)      t_next=0 ;;
    esac
    rh=$((t_next / 3600))
    rm=$(( (t_next % 3600) / 60 ))

    local title body elapsed remain
    elapsed="${h}h${m}m"
    remain="${rh}h${rm}m"

    if _is_zh; then
        title=$(_notify_title_zh "$stage")
        body=$(_notify_body_zh "$stage" "$elapsed" "$remain")
    else
        title=$(_notify_title_en "$stage")
        body=$(_notify_body_en "$stage" "$elapsed" "$remain")
    fi

    local t_esc b_esc
    t_esc=$(_escape_osa "$title")
    b_esc=$(_escape_osa "$body")
    osascript -e "display notification \"${b_esc}\" with title \"${t_esc}\" sound name \"Frog\"" 2>/dev/null || true
    d_notify=$(_now_epoch)
}

# ─── Hook output helpers ──────────────────────────────────────────────────────

_output_continue() {
    # Normal: let IDE continue
    echo '{"continue": true}'
}

_escape_json() {
    # Escape a string for safe embedding inside a JSON double-quoted value.
    # Handles \, ", and control chars (newline/tab/carriage return).
    local s="$1"
    s="${s//\\/\\\\}"   # backslash first
    s="${s//\"/\\\"}"   # double quote
    s="${s//$'\n'/\\n}" # newline
    s="${s//$'\r'/\\r}" # carriage return
    s="${s//$'\t'/\\t}" # tab
    printf '%s' "$s"
}

_output_inject() {
    # Inject additionalContext into UserPromptSubmit.
    # The context is JSON-escaped so newlines / quotes / backslashes in the
    # message can't produce invalid JSON and silently drop the hook output.
    local context
    context=$(_escape_json "$1")
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "$context"
  }
}
EOF
}

_output_block() {
    # Block the prompt (exit code 2 + stderr message)
    local total="$1"
    local h=$((total / 3600)) m=$(( (total % 3600) / 60 ))
    if _is_zh; then
        echo "🔴 [afk] 今天已经肝了 ${h} 时 ${m} 分 (上限 ${T3} 小时), 明天再来吧! 运行 afk.sh reset 可手动解封." >&2
    else
        echo "🔴 [afk] You've been at it for ${h}h ${m}m today (limit: ${T3}h). Call it a day! Run afk.sh reset to unlock." >&2
    fi
    exit 2
}

_inject_message() {
    # Build wind-down message based on current total.
    # Two levels of urgency inside orange:
    #   - early half of orange (T2 ~ T2.5):  ORANGE      — wrap up gracefully
    #   - late  half of orange (T2.5 ~ T3):  ORANGE-CRITICAL — land the plane
    # Both levels are phrased as instructions to the AI (not the user): the AI
    # is the one reading this, and we want it to change its own behavior.
    #
    # Prompt structure follows best practices:
    #   <role> who is speaking  <context> situation  <rules> behavior changes
    local total="$1"
    local dur t3_sec remain remain_fmt
    dur=$(_format_duration "$total")
    t3_sec=$((T3 * 3600))
    remain=$((t3_sec - total))
    remain_fmt=$(_format_duration "$remain")

    local t2_mid=$(( (T2 * 3600 + T3 * 3600) / 2 ))

    if [ "$total" -ge "$t2_mid" ]; then
        # Late orange: finish whatever is in flight, then hand off cleanly.
        cat <<MSG
<afk_anti_addiction role="system">
<context>The user has been working with AI for ${dur} today. All prompts will be blocked in ${remain_fmt}. Stage: ORANGE-CRITICAL.</context>
<rules>
- Finish ONLY the current in-flight operation. Do NOT start new tool calls or subtasks.
- Once done, produce a concise handoff note: what was completed, what remains, and the single next step.
- Stop after the handoff. Do not propose or begin further work.
</rules>
</afk_anti_addiction>
MSG
    else
        # Early orange: polite wind-down.
        cat <<MSG
<afk_anti_addiction role="system">
<context>The user has been working with AI for ${dur} today. All prompts will be blocked in ${remain_fmt}. Stage: ORANGE.</context>
<rules>
- Wrap up the current task. Avoid starting new tasks or large refactors.
- Keep replies short and focused.
- End your reply with a brief progress summary and a TODO list of remaining work.
</rules>
</afk_anti_addiction>
MSG
    fi
}

# ─── Hook: UserPromptSubmit ───────────────────────────────────────────────────

cmd_hook_prompt() {
    cat > /dev/null  # consume stdin

    _load_config
    _load_state

    local now total stage
    now=$(_now_epoch)

    # Close any previously unclosed interval (defensive)
    if [ "$d_start" -gt 0 ]; then
        d_total=$((d_total + now - d_start))
        d_start=0
    fi

    # Start new interval
    d_start="$now"
    d_sessions=$((d_sessions + 1))

    total=$(_current_total)
    stage=$(_stage "$total")

    case "$stage" in
        green)
            _write_data "$d_date" "$d_total" "$d_start" "$d_notify" "$d_sessions"
            _output_continue
            ;;
        yellow)
            if _should_notify; then
                _send_notify "$total" "$stage"
            fi
            _write_data "$d_date" "$d_total" "$d_start" "$d_notify" "$d_sessions"
            _output_continue
            ;;
        orange)
            if _should_notify; then
                _send_notify "$total" "$stage"
            fi
            _write_data "$d_date" "$d_total" "$d_start" "$d_notify" "$d_sessions"
            local msg
            msg=$(_inject_message "$total")
            _output_inject "$msg"
            ;;
        red)
            if _should_notify; then
                _send_notify "$total" "$stage"
            fi
            _write_data "$d_date" "$d_total" "$d_start" "$d_notify" "$d_sessions"
            _output_block "$total"
            ;;
    esac
}

# ─── Hook: Stop ───────────────────────────────────────────────────────────────

cmd_hook_stop() {
    cat > /dev/null  # consume stdin

    _load_config
    _load_state

    local now
    now=$(_now_epoch)

    # Close current interval
    if [ "$d_start" -gt 0 ]; then
        d_total=$((d_total + now - d_start))
        d_start=0
    fi

    _write_data "$d_date" "$d_total" "$d_start" "$d_notify" "$d_sessions"
    _output_continue
}

# ─── Hook: PostToolUse (notify only) ─────────────────────────────────────────
#
# During long tasks (e.g. 45-min refactor), the user may not send new prompts.
# PostToolUse fires on every tool call, so we use it purely for notification
# during these long stretches. No timer, no inject, no block.
#
# Intentionally does NOT checkpoint d_total / d_start here. The single source
# of truth for timer advancement is the UserPromptSubmit → Stop pair. Mixing
# checkpoint semantics into PostToolUse would double-count time or drift when
# hooks arrive out of order. The tradeoff: if the IDE crashes mid-task without
# firing Stop, the in-flight interval is lost — acceptable because the next
# UserPromptSubmit defensively closes any orphan interval.

cmd_hook_post_tool() {
    cat > /dev/null  # consume stdin

    _load_config
    _load_state

    local total stage
    total=$(_current_total)
    stage=$(_stage "$total")

    if [ "$stage" != "green" ] && _should_notify; then
        _send_notify "$total" "$stage"
        # Only persist the throttle timestamp; d_total / d_start stay untouched.
        _write_data "$d_date" "$d_total" "$d_start" "$d_notify" "$d_sessions"
    fi

    _output_continue
}

# ─── Status ───────────────────────────────────────────────────────────────────

cmd_status() {
    _load_config
    _load_state

    local total stage dur
    total=$(_current_total)
    stage=$(_stage "$total")
    dur=$(_format_duration "$total")

    local icon=""
    case "$stage" in
        green)  icon="🟢" ;;
        yellow) icon="🟡" ;;
        orange) icon="🟠" ;;
        red)    icon="🔴" ;;
    esac

    echo ""
    echo "=== afk status ==="
    echo ""
    echo "  today:     $dur  $icon $stage"
    echo "  sessions:  $d_sessions"
    echo "  thresholds: T1=${T1}h (notify)  T2=${T2}h (wind-down)  T3=${T3}h (block)"
    echo ""

    # script installed?
    if [ -f "$INSTALL_PATH" ]; then
        echo "  script:  ✅  $INSTALL_PATH"
    else
        echo "  script:  ❌  not installed ($INSTALL_PATH)"
    fi

    # hooks registered?
    if command -v jq >/dev/null 2>&1; then
        echo ""
        while IFS= read -r ide; do
            local name settings
            name=$(_ide_name "$ide")
            settings=$(_ide_settings "$ide")

            if [ -f "$settings" ]; then
                local hook_events="UserPromptSubmit Stop PostToolUse"
                local all_ok=true
                # Match by HOOK_TAG ("# managed by afk") rather than the bare
                # filename "afk.sh" — safer in case another tool coincidentally
                # has "afk.sh" in its command string.
                for event in $hook_events; do
                    if ! jq -e --arg tag "$HOOK_TAG" \
                        ".hooks.${event}[]? | .hooks[]? | select(.command | contains(\$tag))" \
                        "$settings" >/dev/null 2>&1; then
                        all_ok=false
                        break
                    fi
                done
                if $all_ok; then
                    echo "  hook:    ✅  $name"
                else
                    echo "  hook:    ❌  $name (incomplete)"
                fi
            else
                echo "  hook:    —    $name"
            fi
        done < <(_scan_ides)
    else
        echo "  hook:    ⚠️  jq not installed — cannot check hook registration"
    fi
    echo ""
}

# ─── Set thresholds ───────────────────────────────────────────────────────────

cmd_set() {
    _require jq
    _load_config

    if [ $# -eq 0 ]; then
        echo "Current thresholds: T1=${T1}h  T2=${T2}h  T3=${T3}h"
        echo "Usage: afk.sh set --t1 H --t2 H --t3 H"
        return 0
    fi

    while [ $# -gt 0 ]; do
        case "$1" in
            --t1) shift; T1="${1:-$T1}"; shift ;;
            --t2) shift; T2="${1:-$T2}"; shift ;;
            --t3) shift; T3="${1:-$T3}"; shift ;;
            *) echo "Unknown option: $1 (try --t1, --t2, --t3)" >&2; exit 1 ;;
        esac
    done

    # Validate: must be positive integers (hours). Fractional hours are not
    # supported because downstream arithmetic uses integer * 3600.
    for v in "$T1" "$T2" "$T3"; do
        case "$v" in
            ''|*[!0-9]*|0)
                echo "❌ Thresholds must be positive integers (hours). Got T1=$T1 T2=$T2 T3=$T3" >&2
                exit 1 ;;
        esac
    done

    # Validate order
    if [ "$T1" -ge "$T2" ] || [ "$T2" -ge "$T3" ]; then
        echo "❌ Thresholds must satisfy T1 < T2 < T3 (got T1=$T1 T2=$T2 T3=$T3)" >&2
        exit 1
    fi

    _ensure_data_dir
    cat > "$CONF_FILE" <<EOF
{
  "t1": $T1,
  "t2": $T2,
  "t3": $T3
}
EOF
    echo "✅ Thresholds set: T1=${T1}h  T2=${T2}h  T3=${T3}h"
}

# ─── Reset ────────────────────────────────────────────────────────────────────

cmd_reset() {
    _write_data "$(_today)" 0 0 0 0
    echo "✅ Timer reset for today."
}

# ─── Install ──────────────────────────────────────────────────────────────────

cmd_install() {
    _require jq
    echo ""
    echo "=== afk install ==="
    echo ""

    # show IDE detection info
    if [[ ! "$*" == *"--ide"* ]]; then
        echo "  ℹ️  installing to all detected IDEs (use --ide to target one)"
        echo ""
    fi

    # 1. copy self to ~/.local/bin/afk.sh
    mkdir -p "$INSTALL_DIR"
    local self
    self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    if [ "$self" = "$INSTALL_PATH" ]; then
        echo "  ✅ script already at $INSTALL_PATH"
    else
        cp "$0" "$INSTALL_PATH"
        chmod +x "$INSTALL_PATH"
        echo "  ✅ script → $INSTALL_PATH"
    fi

    # check PATH
    case ":${PATH}:" in
        *":${INSTALL_DIR}:"*) ;;
        *) echo "  ⚠️  add to your shell profile: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
    esac

    # 2. register hooks
    _register_hook() {
        local event="$1" cmd="$2" settings="$3"
        local tagged_cmd="$cmd $HOOK_TAG"
        local hook_entry
        hook_entry=$(jq -n --arg taggedCmd "$tagged_cmd" '{
            "matcher": "",
            "hooks": [{"type": "command", "command": $taggedCmd, "timeout": 5}]
        }')
        if jq -e --arg tag "$HOOK_TAG" \
            ".hooks.${event}[]? | .hooks[]? | select(.command | contains(\$tag))" \
            "$settings" >/dev/null 2>&1; then
            echo "     ✅ hook already registered: $event"
        else
            local tmp="${settings}.tmp"
            jq --argjson entry "$hook_entry" --arg event "$event" '
                .hooks //= {} |
                .hooks[$event] //= [] |
                .hooks[$event] += [$entry]
            ' "$settings" > "$tmp" && mv "$tmp" "$settings"
            echo "     ✅ hook → $event"
        fi
    }

    # create data dir
    _ensure_data_dir

    while IFS= read -r ide; do
        local name settings
        name=$(_ide_name "$ide")
        settings=$(_ide_settings "$ide")

        echo "  [$name]"

        mkdir -p "$(dirname "$settings")"
        if [ ! -f "$settings" ]; then
            echo '{}' > "$settings"
        fi

        _register_hook "UserPromptSubmit" "$HOOK_CMD prompt"    "$settings"
        _register_hook "Stop"             "$HOOK_CMD stop"      "$settings"
        _register_hook "PostToolUse"      "$HOOK_CMD post-tool" "$settings"
        echo ""
    done < <(_resolve_ides "$@")

    echo "  Restart your IDE to activate."
    echo "  Run 'afk.sh status' to verify."
    echo ""
}

# ─── Uninstall ────────────────────────────────────────────────────────────────

cmd_uninstall() {
    _require jq
    echo ""
    echo "=== afk uninstall ==="
    echo ""

    # show IDE detection info
    if [[ ! "$*" == *"--ide"* ]]; then
        echo "  ℹ️  uninstalling from all detected IDEs (use --ide to target one)"
        echo ""
    fi

    # 1. remove hooks from each target IDE's settings.json
    while IFS= read -r ide; do
        local name settings
        name=$(_ide_name "$ide")
        settings=$(_ide_settings "$ide")

        echo "  [$name]"

        if [ -f "$settings" ]; then
            local tmp="${settings}.tmp"
            jq --arg tag "$HOOK_TAG" '
                . as $root |
                ["UserPromptSubmit", "Stop", "PostToolUse"] | reduce .[] as $event ($root;
                    if .hooks[$event] then
                        .hooks[$event] |= [.[] | select(.hooks | all(.command | contains($tag) | not))]
                    else . end |
                    if .hooks[$event] == [] then del(.hooks[$event]) else . end
                ) |
                if .hooks == {} then del(.hooks) else . end
            ' "$settings" > "$tmp" && mv "$tmp" "$settings"

            if jq -e '. == {}' "$settings" >/dev/null 2>&1; then
                echo "  ✅ hooks removed (settings now empty)"
            else
                echo "  ✅ hooks removed"
            fi
        else
            echo "  ℹ️  no settings file found"
        fi
        echo ""
    done < <(_resolve_ides "$@")

    # 2. remove script
    if [ -f "$INSTALL_PATH" ]; then
        rm -f "$INSTALL_PATH"
        echo "  ✅ script removed: $INSTALL_PATH"
    else
        echo "  ℹ️  script not found"
    fi

    # 3. keep data (user may want history)
    echo "  ℹ️  data preserved at $DATA_DIR (delete manually if unwanted)"

    echo ""
    echo "  Done. Restart your IDE to complete."
    echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────

case "${1:-}" in
    prompt)     cmd_hook_prompt ;;
    stop)       cmd_hook_stop ;;
    post-tool)  cmd_hook_post_tool ;;
    status)     cmd_status ;;
    set)        shift; cmd_set "$@" ;;
    reset)      cmd_reset ;;
    install)    shift; cmd_install "$@" ;;
    uninstall)  shift; cmd_uninstall "$@" ;;
    -h|--help)
        echo "afk.sh — AI anti-addiction system (Away From Keyboard)"
        echo ""
        echo "Usage:"
        echo "  afk.sh prompt         Hook mode: UserPromptSubmit (start timer + notify/inject/block)"
        echo "  afk.sh stop           Hook mode: Stop (end timer + persist)"
        echo "  afk.sh post-tool      Hook mode: PostToolUse (notify during long tasks)"
        echo "  afk.sh status         Show today's usage, stage, and hook registration"
        echo "  afk.sh set [opts]     Adjust thresholds (--t1 H --t2 H --t3 H)"
        echo "  afk.sh reset          Reset today's timer"
        echo "  afk.sh install        Install to ~/.local/bin/ and register hooks"
        echo "  afk.sh uninstall      Remove hooks, remove script, keep data"
        echo ""
        echo "Options:"
        echo "  install/uninstall --ide <name>   Target IDE"
        echo "                                  Supported: claude codebuddy cursor cline augment windsurf"
        echo "                                  Default: auto-detect"
        echo ""
        echo "Environment:"
        echo "  AFK_T1      Green → Yellow threshold in hours (default: 8)"
        echo "  AFK_T2      Yellow → Orange threshold in hours (default: 10)"
        echo "  AFK_T3      Orange → Red threshold in hours (default: 12)"
        echo ""
        echo "Stages:"
        echo "  🟢 green   0 ~ T1h    Normal, no intervention"
        echo "  🟡 yellow  T1 ~ T2h   macOS notification reminders"
        echo "  🟠 orange  T2 ~ T3h   Inject wind-down prompt into AI context"
        echo "  🔴 red     T3h+       Block all new prompts"
        ;;
    *)
        echo "Unknown command: ${1:-} (try 'afk.sh --help')" >&2
        exit 1 ;;
esac
