#!/bin/sh
# session-primer — keep an AI coding CLI's 5-hour usage window always open.
#
# Designed to run every minute from launchd/systemd/cron. Each run ("tick"):
#   claude: if the tracked window has expired (or nothing is tracked), send one
#           tiny prompt. Its stream-json response carries Anthropic's own
#           rate_limit_event with the exact reset time — that becomes the next
#           trigger time. Nothing is estimated.
#   codex:  read account/rateLimits/read from the codex app-server (free, no
#           quota spent). If a 5-hour window is open, adopt its exact reset
#           time; if none is open, send one tiny prompt to start one.
#
# The result: windows chain back-to-back, so whenever you sit down to work a
# window is already ticking and the next reset is never more than 5h away.
#
# This does NOT create quota. Weekly caps still apply. ~5 triggers/day/tool.
#
# Usage: primer.sh [--dry-run] [--sync] [--tool claude|codex] [--status] [--doctor]
#                  [--watch] [--set-end TOOL HH:MM]

set -u

VERSION="0.5.1"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/session-primer"
CONFIG_FILE="$CONFIG_DIR/primer.conf"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/session-primer"
BLANK_DIR="$STATE_DIR/blank"   # empty cwd so no project context inflates the prompt
LOG_FILE="$STATE_DIR/primer.log"
LOCK_DIR="$STATE_DIR/lock"

# ---- Defaults (override in $CONFIG_FILE) ------------------------------------
TOOLS="claude"                       # space-separated: claude codex
PROMPT="Reply with exactly: ok"      # the trigger message
CLAUDE_MODEL="haiku"                 # cheapest model = smallest quota dent
CODEX_MODEL=""                       # empty = codex config default
CODEX_EFFORT="low"                   # reasoning effort for the trigger (empty = config default)
WINDOW_HOURS=5                       # provider window length
TIMEOUT_SECS=180                     # kill a hung trigger after this long
FAIL_RETRY_SECS=600                  # after a failure, wait this long before retrying
RATE_REFRESH_SECS=300                # codex: re-read provider usage this often (free)
# -----------------------------------------------------------------------------

[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

export PATH="$HOME/.local/bin:$PATH"
[ -n "${APPDATA:-}" ] && [ -d "$APPDATA/npm" ] && export PATH="$APPDATA/npm:$PATH"

mkdir -p "$STATE_DIR" "$BLANK_DIR"

DRY_RUN=0
FORCE=0
ONLY_TOOL=""
SHOW_STATUS=0
DOCTOR=0
WATCH=0
WATCH_ONCE=0
SET_TOOL=""
SET_TIME=""

usage() {
    cat <<EOF
session-primer $VERSION — keep AI coding CLI 5-hour usage windows chained open

Usage: primer.sh [options]

Options:
  --dry-run        Show what this tick would do without sending anything
  --sync           Re-check the provider now. claude: one tiny probe prompt.
                   codex: a free usage read (triggers only if no window is open)
  --force          Alias of --sync
  --tool NAME      Only handle one tool (claude or codex)
  --status         Show window state per tool and recent log entries
  --doctor         Check CLIs, sign-in, scheduler and heartbeat; explain any problem
  --watch          Live dashboard — visualize windows and triggers (ctrl+c exits)
  --set-end TOOL HH:MM
                   Manually override the tracked window end (rarely needed)
  -h, --help       Show this help

Config file: $CONFIG_FILE
Log file:    $LOG_FILE
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --force|--sync) FORCE=1 ;;
        --tool)    ONLY_TOOL="${2:-}"; shift ;;
        --status)  SHOW_STATUS=1 ;;
        --doctor)  DOCTOR=1 ;;
        --watch)   WATCH=1 ;;
        --watch-once) WATCH_ONCE=1 ;;
        --set-end)
            [ $# -ge 3 ] || { echo "error: --set-end needs TOOL and HH:MM (e.g. --set-end claude 21:20)" >&2; exit 2; }
            SET_TOOL="$2"; SET_TIME="$3"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

log() {
    _msg="$(date '+%Y-%m-%d %H:%M:%S') $*"
    echo "$_msg"
    echo "$_msg" >> "$LOG_FILE"
}

# ---- portability shims (BSD vs GNU) -----------------------------------------
fmt_time() {
    if date -r 0 '+%s' >/dev/null 2>&1; then
        date -r "$1" '+%Y-%m-%d %H:%M'
    else
        date -d "@$1" '+%Y-%m-%d %H:%M'
    fi
}

# Epoch for today's HH:MM (BSD and GNU date).
today_at() {
    _d=$(date '+%Y-%m-%d')
    if date -j >/dev/null 2>&1; then
        date -j -f '%Y-%m-%d %H:%M' "$_d $1" '+%s' 2>/dev/null
    else
        date -d "$_d $1" '+%s' 2>/dev/null
    fi
}

read_epoch_file() {
    _v=$(cat "$1" 2>/dev/null)
    case "$_v" in
        ''|*[!0-9]*) echo "" ;;
        *) echo "$_v" ;;
    esac
}

pct() { awk "BEGIN { printf \"%d\", (${1:-0}) * 100 + 0.5 }"; }

claude_signed_in() { claude auth status 2>/dev/null | grep -q '"loggedIn": *true'; }
codex_signed_in()  { codex login status 2>&1 | grep -qi '^logged in'; }

# Seconds since the daemon last ticked, or empty if it never has.
tick_age() {
    _lt=$(read_epoch_file "$STATE_DIR/last-tick")
    [ -n "$_lt" ] && echo $(( $(date +%s) - _lt ))
}

# The heartbeat counts as stale after three missed ticks (install.sh records
# the interval it scheduled), never sooner than 180s.
stale_after() {
    _iv=$(read_epoch_file "$STATE_DIR/tick-interval")
    _st=$(( ${_iv:-60} * 3 ))
    [ "$_st" -lt 180 ] && _st=180
    echo "$_st"
}

if [ -n "$SET_TOOL" ]; then
    case "$SET_TOOL" in claude|codex) ;; *) echo "error: --set-end expects claude or codex" >&2; exit 2 ;; esac
    _e=$(today_at "$SET_TIME")
    [ -n "$_e" ] || { echo "error: --set-end time must be HH:MM (24h)" >&2; exit 2; }
    [ "$_e" -le "$(date +%s)" ] && _e=$((_e + 86400))   # earlier than now = tomorrow
    echo "$_e" > "$STATE_DIR/window-end-$SET_TOOL"
    rm -f "$STATE_DIR/last-fail-$SET_TOOL"
    log "$SET_TOOL: window end set manually to $(fmt_time "$_e") — next trigger at that time"
    exit 0
fi

# Run "$@" but kill it after $1 seconds (portable; macOS has no `timeout`).
# The command runs as a background job; a function passed here should `exec`
# its final command so the kill reaches the real process, not a wrapper shell.
# The watchdog's stdio is detached: otherwise its sleep keeps the caller's
# stdout pipe open and a $(...) around this function blocks for the full timeout.
run_with_timeout() {
    _secs=$1; shift
    "$@" &
    _cmd_pid=$!
    ( sleep "$_secs" && kill "$_cmd_pid" 2>/dev/null ) >/dev/null 2>&1 &
    _watchdog_pid=$!
    wait "$_cmd_pid"
    _rc=$?
    kill "$_watchdog_pid" 2>/dev/null
    wait "$_watchdog_pid" 2>/dev/null
    return $_rc
}

# ---- claude -----------------------------------------------------------------
# Runs in $BLANK_DIR with everything non-essential disabled, so the trigger
# consumes as few tokens as possible. stream-json makes Claude Code emit a
# rate_limit_event with the provider's own view of the usage windows.
run_claude() {
    exec claude -p "$PROMPT" \
        --model "$CLAUDE_MODEL" \
        --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
        --setting-sources project \
        --no-session-persistence \
        --output-format stream-json --verbose
}

RL_5H_RESET=""; RL_5H_UTIL=""; RL_7D_RESET=""; RL_7D_UTIL=""
parse_claude_rate_limits() {
    RL_5H_RESET=""; RL_5H_UTIL=""; RL_7D_RESET=""; RL_7D_UTIL=""
    _ev=$(grep '"rate_limit_event"' "$1" 2>/dev/null | tail -n 1)
    [ -n "$_ev" ] || return 1
    _fh=$(printf '%s' "$_ev" | grep -o '"five_hour":{[^}]*}' | head -n 1)
    _sd=$(printf '%s' "$_ev" | grep -o '"seven_day":{[^}]*}' | head -n 1)
    RL_5H_RESET=$(printf '%s' "$_fh" | grep -o '"resetsAt":[0-9]*' | cut -d: -f2)
    RL_5H_UTIL=$(printf '%s' "$_fh" | grep -o '"utilization":[0-9.]*' | cut -d: -f2)
    RL_7D_RESET=$(printf '%s' "$_sd" | grep -o '"resetsAt":[0-9]*' | cut -d: -f2)
    RL_7D_UTIL=$(printf '%s' "$_sd" | grep -o '"utilization":[0-9.]*' | cut -d: -f2)
    [ -n "$RL_5H_RESET" ]
}

save_rate_file() {   # $1 tool, $2..$5 = 5h reset, 5h util, 7d reset, 7d util
    printf 'FIVE_HOUR_RESET=%s\nFIVE_HOUR_UTIL=%s\nSEVEN_DAY_RESET=%s\nSEVEN_DAY_UTIL=%s\nCHECKED_AT=%s\n' \
        "$2" "$3" "$4" "$5" "$(date +%s)" > "$STATE_DIR/rate-$1"
}

# ---- codex ------------------------------------------------------------------
run_codex() {
    set -- codex exec --skip-git-repo-check -C "$BLANK_DIR"
    [ -n "$CODEX_MODEL" ]  && set -- "$@" -m "$CODEX_MODEL"
    [ -n "$CODEX_EFFORT" ] && set -- "$@" -c "model_reasoning_effort=\"$CODEX_EFFORT\""
    exec "$@" "$PROMPT"
}

# account/rateLimits/read over the app-server's stdio JSON-RPC: the provider's
# windows (usedPercent, windowDurationMins, resetsAt) without spending quota.
codex_rpc_raw() {
    (
        printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"session-primer\",\"version\":\"$VERSION\"}}}"
        sleep 1
        printf '%s\n' '{"jsonrpc":"2.0","method":"initialized"}'
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}'
        sleep 4
    ) | codex app-server 2>/dev/null | grep '"id":2[^0-9]' | head -n 1
}

CX_STATE=""; CX_PLAN=""; CX_ERR=""; CX_5H_RESET=""; CX_5H_UTIL=""; CX_7D_RESET=""; CX_7D_UTIL=""
# Sets CX_STATE: ok | no-5h-window | unavailable
codex_rate_read() {
    CX_STATE="unavailable"; CX_PLAN=""; CX_ERR=""; CX_5H_RESET=""; CX_5H_UTIL=""; CX_7D_RESET=""; CX_7D_UTIL=""
    # Capture to a file rather than $(...): if the app-server hangs past the
    # timeout, the orphaned pipeline must not keep this tick blocked.
    _rpc_file="$STATE_DIR/last-codex-rpc.out"
    run_with_timeout 30 codex_rpc_raw > "$_rpc_file" 2>/dev/null
    _raw=$(cat "$_rpc_file" 2>/dev/null)
    if [ -z "$_raw" ]; then
        CX_ERR="no response from codex app-server — not signed in?"
        return 1
    fi
    CX_ERR=$(printf '%s' "$_raw" | grep -o '"error":{[^}]*}' | grep -o '"message":"[^"]*"' | head -n 1 | cut -d'"' -f4 | tr -d "'")
    CX_PLAN=$(printf '%s' "$_raw" | grep -o '"planType":"[^"]*"' | head -n 1 | cut -d'"' -f4 | tr -d "'")
    _p=$(printf '%s' "$_raw" | grep -o '"primary":{[^}]*}' | head -n 1)
    _s=$(printf '%s' "$_raw" | grep -o '"secondary":{[^}]*}' | head -n 1)
    if [ -z "$_p$_s" ]; then
        [ -n "$CX_ERR" ] || CX_ERR="no rate-limit data in response"
        return 1
    fi
    for _w in "$_p" "$_s"; do
        [ -n "$_w" ] || continue
        _dur=$(printf '%s' "$_w" | grep -o '"windowDurationMins":[0-9]*' | cut -d: -f2)
        _rst=$(printf '%s' "$_w" | grep -o '"resetsAt":[0-9]*' | cut -d: -f2)
        _use=$(printf '%s' "$_w" | grep -o '"usedPercent":[0-9]*' | cut -d: -f2)
        [ -n "$_dur" ] || continue
        if [ "$_dur" -le $((WINDOW_HOURS * 60)) ]; then
            CX_5H_RESET=$_rst; CX_5H_UTIL=$(awk "BEGIN { print (${_use:-0}) / 100 }")
        elif [ "$_dur" -ge 10000 ] && [ "$_dur" -le 11000 ]; then
            CX_7D_RESET=$_rst; CX_7D_UTIL=$(awk "BEGIN { print (${_use:-0}) / 100 }")
        fi
    done
    if [ -n "$CX_5H_UTIL" ]; then CX_STATE="ok"; else CX_STATE="no-5h-window"; fi
    return 0
}

save_codex_state() {
    date +%s > "$STATE_DIR/codex-checked"
    printf "STATE='%s'\nPLAN='%s'\nERR='%s'\n" "$CX_STATE" "$CX_PLAN" "$CX_ERR" > "$STATE_DIR/codex-state"
    [ "$CX_STATE" = ok ] && save_rate_file codex "$CX_5H_RESET" "$CX_5H_UTIL" "$CX_7D_RESET" "$CX_7D_UTIL"
}

# ---- display helpers --------------------------------------------------------
# One line of provider-reported usage, empty if never read.
rate_summary() {
    _rf="$STATE_DIR/rate-$1"
    [ -f "$_rf" ] || return 0
    FIVE_HOUR_UTIL=""; SEVEN_DAY_UTIL=""; SEVEN_DAY_RESET=""; CHECKED_AT=""
    . "$_rf"
    _wk=""
    [ -n "$SEVEN_DAY_UTIL" ] && _wk=" · weekly used $(pct "$SEVEN_DAY_UTIL")% (resets $(fmt_time "${SEVEN_DAY_RESET:-0}"))"
    printf '5h used %s%%%s · provider data from %s' \
        "$(pct "$FIVE_HOUR_UTIL")" "$_wk" "$(fmt_time "${CHECKED_AT:-0}" | cut -d' ' -f2)"
}

# For codex: a non-empty line means the tool is not in a primeable state.
codex_special_state() {
    [ -f "$STATE_DIR/codex-state" ] || return 0
    STATE=""; PLAN=""; ERR=""
    . "$STATE_DIR/codex-state"
    case "$STATE" in
        unavailable)   printf 'usage unreadable (%s) — sign in here with: codex login --device-auth' "$ERR" ;;
        no-5h-window)  printf 'signed in (plan: %s) — this plan has no 5-hour window, nothing to prime' "${PLAN:-unknown}" ;;
    esac
}

# ---- status -----------------------------------------------------------------
status() {
    echo "session-primer $VERSION (chain mode)"
    echo
    echo "Config file : $CONFIG_FILE $( [ -f "$CONFIG_FILE" ] && echo '(present)' || echo '(not created — using defaults)')"
    echo "Tools       : $TOOLS"
    echo "Claude model: $CLAUDE_MODEL"
    _age=$(tick_age)
    if [ -n "$_age" ]; then
        if [ "$_age" -lt "$(stale_after)" ]; then echo "Daemon      : alive — last tick ${_age}s ago"; else echo "Daemon      : NOT TICKING — last tick $((_age / 60))m ago (run ./primer.sh --doctor)"; fi
    else
        echo "Daemon      : no tick recorded yet (run ./install.sh)"
    fi
    echo
    _now=$(date +%s)
    for t in $TOOLS; do
        if ! command -v "$t" >/dev/null 2>&1; then
            echo "$t: NOT FOUND on PATH"
            continue
        fi
        if [ "$t" = codex ]; then
            _sp=$(codex_special_state)
            if [ -n "$_sp" ]; then echo "codex: $_sp"; continue; fi
        fi
        _we=$(read_epoch_file "$STATE_DIR/window-end-$t")
        if [ -n "$_we" ] && [ "$_now" -lt "$_we" ]; then
            _left=$(( (_we - _now) / 60 ))
            echo "$t: window OPEN until $(fmt_time "$_we") ($((_left / 60))h $((_left % 60))m left) — next trigger at expiry"
        elif [ -n "$_we" ]; then
            echo "$t: window EXPIRED at $(fmt_time "$_we") — next tick will trigger"
        else
            echo "$t: no window tracked — next tick checks the provider and triggers if needed"
        fi
        _rs=$(rate_summary "$t"); [ -n "$_rs" ] && echo "        $_rs"
    done
    echo
    if [ -f "$LOG_FILE" ]; then
        echo "Last log entries:"
        tail -n 8 "$LOG_FILE"
    else
        echo "No log yet ($LOG_FILE)"
    fi
}

doctor() {
    _fail=0
    ok()   { printf '  [ok]   %s\n' "$*"; }
    bad()  { printf '  [FAIL] %s\n' "$*"; _fail=1; }
    warn() { printf '  [warn] %s\n' "$*"; }
    echo "session-primer $VERSION — doctor"
    echo
    if [ -f "$CONFIG_FILE" ]; then ok "config: $CONFIG_FILE (tools: $TOOLS)"; else warn "config not created yet — using defaults (tools: $TOOLS); ./install.sh writes it"; fi
    if [ -w "$STATE_DIR" ]; then ok "state dir writable: $STATE_DIR"; else bad "state dir not writable: $STATE_DIR"; fi
    for t in $TOOLS; do
        if _p=$(command -v "$t" 2>/dev/null); then
            ok "$t found: $_p ($("$t" --version 2>/dev/null | head -n 1))"
            if "${t}_signed_in"; then
                ok "$t signed in"
            elif [ "$t" = claude ]; then
                bad "$t NOT signed in — run: claude auth login   (choose the subscription login)"
            else
                bad "$t NOT signed in — run: codex login   (headless: codex login --device-auth)"
            fi
        else
            bad "$t not found on PATH — run ./setup.sh"
        fi
    done
    case "$(uname -s)" in
        Darwin)
            if launchctl print "gui/$(id -u)/com.session-primer" >/dev/null 2>&1; then ok "scheduler: launchd agent loaded"; else bad "scheduler: launchd agent not loaded — run ./install.sh"; fi ;;
        Linux)
            export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
            if systemctl --user is-active session-primer.timer >/dev/null 2>&1; then
                ok "scheduler: systemd user timer active"
                _u=${USER:-$(id -un)}
                if loginctl show-user "$_u" 2>/dev/null | grep -q '^Linger=yes'; then ok "lingering enabled (timer survives logout)"; else warn "lingering NOT enabled — timer stops when you log out: sudo loginctl enable-linger $_u"; fi
            elif crontab -l 2>/dev/null | grep -q '# session-primer$'; then ok "scheduler: cron entry present"
            else bad "scheduler: no systemd timer or cron entry — run ./install.sh"; fi ;;
        MINGW*|MSYS*|CYGWIN*)
            if MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' schtasks /Query /TN session-primer >/dev/null 2>&1; then ok "scheduler: Task Scheduler task present"; else bad "scheduler: task 'session-primer' missing — run ./install.sh from Git Bash"; fi ;;
    esac
    _age=$(tick_age)
    if [ -z "$_age" ]; then warn "heartbeat: no tick recorded yet (the scheduler ticks within a minute of install)"
    elif [ "$_age" -lt "$(stale_after)" ]; then ok "heartbeat: last tick ${_age}s ago"
    else bad "heartbeat: last tick $((_age / 60))m ago — the scheduler is not running the script (see README troubleshooting)"; fi
    _now=$(date +%s)
    for t in $TOOLS; do
        _we=$(read_epoch_file "$STATE_DIR/window-end-$t")
        if [ "$t" = codex ] && [ -n "$(codex_special_state)" ]; then warn "codex: $(codex_special_state)"
        elif [ -n "$_we" ] && [ "$_now" -lt "$_we" ]; then ok "$t window tracked: open until $(fmt_time "$_we")"
        elif [ -n "$_we" ]; then warn "$t window expired at $(fmt_time "$_we") — the next tick should trigger"
        else warn "$t: no window tracked yet — the next tick probes the provider"; fi
        _lf=$(read_epoch_file "$STATE_DIR/last-fail-$t")
        [ -n "$_lf" ] && warn "$t: last attempt failed at $(fmt_time "$_lf") — see $STATE_DIR/last-$t.out"
    done
    echo
    if [ "$_fail" -eq 0 ]; then echo "All checks passed."; else echo "Problems found — fix the [FAIL] lines above."; fi
    return $_fail
}

if [ "$DOCTOR" -eq 1 ]; then
    doctor
    exit $?
fi

if [ "$SHOW_STATUS" -eq 1 ]; then
    status
    exit 0
fi

# ---- live watch UI ----------------------------------------------------------
ESC=$(printf '\033')

draw_bar() {
    _elapsed=$1; _total=$2; _width=$3
    _filled=$((_elapsed * _width / _total))
    [ "$_filled" -gt "$_width" ] && _filled=$_width
    [ "$_filled" -lt 0 ] && _filled=0
    _i=0
    while [ "$_i" -lt "$_width" ]; do
        if [ "$_i" -lt "$_filled" ]; then printf '█'; else printf '░'; fi
        _i=$((_i + 1))
    done
}

daemon_state() {
    _age=$(tick_age)
    if [ -n "$_age" ]; then
        if [ "$_age" -lt "$(stale_after)" ]; then _hb=" · last tick ${_age}s ago"; else _hb=" · LAST TICK $((_age / 60))m AGO"; fi
    else
        _hb=" · no tick yet"
    fi
    case "$(uname -s)" in
        Darwin)
            if launchctl print "gui/$(id -u)/com.session-primer" >/dev/null 2>&1; then
                printf 'loaded%s' "$_hb"
            else
                printf 'NOT LOADED — run ./install.sh'
            fi ;;
        Linux)
            if systemctl --user is-active session-primer.timer >/dev/null 2>&1 \
               || crontab -l 2>/dev/null | grep -q '# session-primer$'; then
                printf 'loaded%s' "$_hb"
            else
                printf 'NOT LOADED — run ./install.sh'
            fi ;;
        MINGW*|MSYS*|CYGWIN*)
            if MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' schtasks /Query /TN session-primer >/dev/null 2>&1; then
                printf 'loaded (Task Scheduler)%s' "$_hb"
            else
                printf 'NOT LOADED — run ./install.sh from Git Bash'
            fi ;;
        *) printf 'unknown platform' ;;
    esac
}

render_tool_row() {
    _t=$1; _rnow=$2
    if ! command -v "$_t" >/dev/null 2>&1; then
        printf '  %-7s %sCLI not found on PATH%s\n' "$_t" "${ESC}[2m" "${ESC}[0m"
        return
    fi
    if [ "$_t" = codex ]; then
        _sp=$(codex_special_state)
        if [ -n "$_sp" ]; then
            printf '  %-7s %s%s%s\n' "$_t" "${ESC}[33m" "$_sp" "${ESC}[0m"
            return
        fi
    fi
    _we=$(read_epoch_file "$STATE_DIR/window-end-$_t")
    _total=$((WINDOW_HOURS * 3600))
    if [ -z "$_we" ]; then
        printf '  %-7s %sno window tracked — next tick checks the provider%s\n' "$_t" "${ESC}[33m" "${ESC}[0m"
        return
    fi
    if [ "$_rnow" -ge "$_we" ]; then
        _fail=$(read_epoch_file "$STATE_DIR/last-fail-$_t")
        if [ -n "$_fail" ] && [ $((_rnow - _fail)) -lt "$FAIL_RETRY_SECS" ]; then
            printf '  %-7s %sEXPIRED — last attempt failed, retry in ~%sm%s\n' "$_t" "${ESC}[31m" "$(( (FAIL_RETRY_SECS - (_rnow - _fail)) / 60 + 1 ))" "${ESC}[0m"
        else
            printf '  %-7s %sEXPIRED — trigger fires within 60s%s\n' "$_t" "${ESC}[31m" "${ESC}[0m"
        fi
        return
    fi
    _left=$((_we - _rnow))
    _elapsed=$((_total - _left))
    _col="${ESC}[32m"
    [ "$_left" -lt 3600 ] && _col="${ESC}[33m"
    printf '  %-7s %s[%s]%s  %dh %02dm left   %s → %s\n' \
        "$_t" "$_col" "$(draw_bar "$_elapsed" "$_total" 24)" "${ESC}[0m" \
        "$((_left / 3600))" "$(((_left % 3600) / 60))" \
        "$(fmt_time $((_we - _total)) | cut -d' ' -f2)" \
        "$(fmt_time "$_we" | cut -d' ' -f2)"
    _rs=$(rate_summary "$_t")
    [ -n "$_rs" ] && printf '          %s%s%s\n' "${ESC}[2m" "$_rs" "${ESC}[0m"
}

render_frame() {
    _rnow=$(date +%s)
    printf '%ssession-primer%s — live  %s%s  (exit: ctrl+c)%s\n' "${ESC}[1m" "${ESC}[0m" "${ESC}[2m" "$(date '+%a %H:%M:%S')" "${ESC}[0m"
    printf '  daemon  %s\n\n' "$(daemon_state)"
    for _t in $TOOLS; do
        render_tool_row "$_t" "$_rnow"
    done
    printf '\n  %s5h windows chain automatically: when one expires, a tiny trigger starts the next.%s\n' "${ESC}[2m" "${ESC}[0m"
    printf '\n  %srecent events%s\n' "${ESC}[1m" "${ESC}[0m"
    if [ -f "$LOG_FILE" ]; then
        _cols=$( (tput cols) 2>/dev/null || echo 120)
        case "$_cols" in ''|*[!0-9]*) _cols=120 ;; esac
        _max=$((_cols - 4)); [ "$_max" -lt 40 ] && _max=40
        tail -n 5 "$LOG_FILE" | while IFS= read -r _l; do
            printf '  %s%s%s\n' "${ESC}[2m" "$(printf '%s' "$_l" | cut -c1-"$_max")" "${ESC}[0m"
        done
    else
        printf '  %s(no events yet)%s\n' "${ESC}[2m" "${ESC}[0m"
    fi
}

watch_ui() {
    # Alternate screen buffer (like htop/less): redraw in place, no scrollback
    # pollution, terminal restored exactly on exit.
    trap 'printf "%s" "${ESC}[?1049l${ESC}[?25h"; exit 0' INT TERM
    printf '%s' "${ESC}[?1049h${ESC}[?25l"
    while :; do
        _frame=$(render_frame)
        printf '%s%s\n%s' "${ESC}[H" "$_frame" "${ESC}[0J"
        sleep 2
    done
}

if [ "$WATCH_ONCE" -eq 1 ]; then
    render_frame
    exit 0
fi
if [ "$WATCH" -eq 1 ]; then
    watch_ui
    exit 0
fi

# ---- lock: never let two ticks overlap --------------------------------------
if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo $$ > "$LOCK_DIR/pid"
else
    _lp=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    if [ -n "$_lp" ] && kill -0 "$_lp" 2>/dev/null; then
        exit 0   # a previous tick is still running
    fi
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || exit 0
    echo $$ > "$LOCK_DIR/pid"
fi
trap 'rm -rf "$LOCK_DIR"' EXIT
trap 'rm -rf "$LOCK_DIR"; trap - EXIT; exit 1' INT TERM

# ---- ticks ------------------------------------------------------------------
now=$(date +%s)
[ "$DRY_RUN" -eq 1 ] || echo "$now" > "$STATE_DIR/last-tick"

in_backoff() {   # $1 tool
    _lf=$(read_epoch_file "$STATE_DIR/last-fail-$1")
    [ "$FORCE" -eq 0 ] && [ -n "$_lf" ] && [ $((now - _lf)) -lt "$FAIL_RETRY_SECS" ]
}

tick_claude() {
    wend_file="$STATE_DIR/window-end-claude"
    fail_file="$STATE_DIR/last-fail-claude"
    wend=$(read_epoch_file "$wend_file")

    if [ "$FORCE" -eq 0 ] && [ -n "$wend" ] && [ "$now" -lt "$wend" ]; then
        [ "$DRY_RUN" -eq 1 ] && echo "claude: window open until $(fmt_time "$wend") — would do nothing"
        return
    fi
    if in_backoff claude; then
        [ "$DRY_RUN" -eq 1 ] && echo "claude: recent failure — backing off"
        return
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        if [ -z "$wend" ]; then
            echo "claude: no window tracked — would send a probe now (its response carries the provider's reset time)"
        else
            echo "claude: window expired — would send trigger now"
        fi
        return
    fi

    out_file="$STATE_DIR/last-claude.out"
    if [ -z "$wend" ]; then
        log "claude: no window tracked — sending probe to learn the provider's reset time..."
    elif [ "$FORCE" -eq 1 ]; then
        log "claude: sync requested — sending probe..."
    else
        log "claude: window expired — sending trigger to start the next one..."
    fi
    fire_time=$(date +%s)
    if ( cd "$BLANK_DIR" && run_with_timeout "$TIMEOUT_SECS" run_claude > "$out_file" 2>&1 ); then
        rm -f "$fail_file"
        if parse_claude_rate_limits "$out_file"; then
            echo "$RL_5H_RESET" > "$wend_file"
            save_rate_file claude "$RL_5H_RESET" "$RL_5H_UTIL" "$RL_7D_RESET" "$RL_7D_UTIL"
            log "claude: trigger OK — provider says window resets $(fmt_time "$RL_5H_RESET") (5h used $(pct "$RL_5H_UTIL")%, weekly $(pct "$RL_7D_UTIL")%)"
        else
            echo $((fire_time + WINDOW_HOURS * 3600)) > "$wend_file"
            log "claude: trigger OK — window open until $(fmt_time $((fire_time + WINDOW_HOURS * 3600))) (no rate_limit_event in response)"
        fi
    else
        rc=$?
        if parse_claude_rate_limits "$out_file" && [ "$RL_5H_RESET" -gt "$now" ]; then
            echo "$RL_5H_RESET" > "$wend_file"
            save_rate_file claude "$RL_5H_RESET" "$RL_5H_UTIL" "$RL_7D_RESET" "$RL_7D_UTIL"
            log "claude: trigger rejected (exit $rc) but provider reports the window resets $(fmt_time "$RL_5H_RESET") — will trigger then"
        else
            date +%s > "$fail_file"
            log "claude: trigger FAILED (exit $rc) — will retry in $((FAIL_RETRY_SECS / 60))m, see $out_file"
        fi
    fi
}

tick_codex() {
    wend_file="$STATE_DIR/window-end-codex"
    fail_file="$STATE_DIR/last-fail-codex"
    wend=$(read_epoch_file "$wend_file")
    last_read=$(read_epoch_file "$STATE_DIR/codex-checked")
    fresh=0
    [ -n "$last_read" ] && [ $((now - last_read)) -lt "$RATE_REFRESH_SECS" ] && fresh=1

    # Window tracked open and usage recently read: nothing to do.
    if [ "$FORCE" -eq 0 ] && [ -n "$wend" ] && [ "$now" -lt "$wend" ] && [ "$fresh" -eq 1 ]; then
        [ "$DRY_RUN" -eq 1 ] && echo "codex: window open until $(fmt_time "$wend") — would do nothing"
        return
    fi
    # Nothing primeable (free plan / not signed in) and checked recently: wait.
    if [ "$FORCE" -eq 0 ] && [ -z "$wend" ] && [ "$fresh" -eq 1 ] && [ -n "$(codex_special_state)" ]; then
        [ "$DRY_RUN" -eq 1 ] && echo "codex: $(codex_special_state)"
        return
    fi
    if in_backoff codex; then
        [ "$DRY_RUN" -eq 1 ] && echo "codex: recent failure — backing off"
        return
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "codex: would read usage from the provider (free) and trigger only if no 5h window is open"
        return
    fi

    codex_rate_read; save_codex_state
    case "$CX_STATE" in
        unavailable)
            date +%s > "$fail_file"
            rm -f "$wend_file"   # a tracked window means nothing without a working login
            log "codex: cannot read usage — $CX_ERR. Sign in on this machine with: codex login --device-auth (retry in $((FAIL_RETRY_SECS / 60))m, or run --sync)"
            return ;;
        no-5h-window)
            if [ "$(cat "$STATE_DIR/codex-plan-logged" 2>/dev/null)" != "$CX_PLAN" ]; then
                printf '%s' "$CX_PLAN" > "$STATE_DIR/codex-plan-logged"
                log "codex: signed in (plan: ${CX_PLAN:-unknown}) but this plan has no 5-hour window — nothing to prime until it does"
            fi
            rm -f "$wend_file"
            return ;;
    esac
    rm -f "$STATE_DIR/codex-plan-logged"

    # A 5-hour window is open (ours or one your own usage started): adopt it.
    if [ -n "$CX_5H_RESET" ] && [ "$CX_5H_RESET" -gt "$now" ]; then
        if [ "$CX_5H_RESET" != "$wend" ]; then
            echo "$CX_5H_RESET" > "$wend_file"
            log "codex: provider says a window is open until $(fmt_time "$CX_5H_RESET") (5h used $(pct "$CX_5H_UTIL")%) — no trigger needed"
        fi
        return
    fi

    # No open 5-hour window: start one.
    out_file="$STATE_DIR/last-codex.out"
    log "codex: no 5h window open — sending trigger to start one..."
    fire_time=$(date +%s)
    if ( cd "$BLANK_DIR" && run_with_timeout "$TIMEOUT_SECS" run_codex > "$out_file" 2>&1 ); then
        rm -f "$fail_file"
        codex_rate_read; save_codex_state
        if [ "$CX_STATE" = ok ] && [ -n "$CX_5H_RESET" ] && [ "$CX_5H_RESET" -gt "$fire_time" ]; then
            echo "$CX_5H_RESET" > "$wend_file"
            log "codex: trigger OK — provider says window resets $(fmt_time "$CX_5H_RESET") (5h used $(pct "$CX_5H_UTIL")%, weekly $(pct "$CX_7D_UTIL")%)"
        else
            echo $((fire_time + WINDOW_HOURS * 3600)) > "$wend_file"
            log "codex: trigger OK — window open until $(fmt_time $((fire_time + WINDOW_HOURS * 3600))) (provider reset not reported yet)"
        fi
    else
        rc=$?
        date +%s > "$fail_file"
        log "codex: trigger FAILED (exit $rc) — will retry in $((FAIL_RETRY_SECS / 60))m, see $out_file"
    fi
}

for tool in $TOOLS; do
    [ -n "$ONLY_TOOL" ] && [ "$tool" != "$ONLY_TOOL" ] && continue
    case "$tool" in
        claude|codex) ;;
        *) log "$tool: unknown tool in TOOLS, skipping"; continue ;;
    esac
    if ! command -v "$tool" >/dev/null 2>&1; then
        log "$tool: CLI not found on PATH, skipping"
        continue
    fi
    "tick_$tool"
done
