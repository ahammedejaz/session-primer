#!/bin/sh
# session-primer installer — runs primer.sh as a once-a-minute tick so usage
# windows chain back-to-back automatically. No times to configure.
#   macOS   : launchd user agent (StartInterval; catches up after sleep)
#   Linux   : systemd user timer (Persistent=true); cron fallback
#   Windows : Task Scheduler running the script under Git Bash (run from Git Bash)
#
# Usage:
#   ./install.sh                          # auto-detect tools, interactive
#   ./install.sh --tools "claude codex"   # non-interactive
#   ./install.sh --dry-run                # show what would be installed

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PRIMER="$SCRIPT_DIR/primer.sh"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/session-primer"
CONFIG_FILE="$CONFIG_DIR/primer.conf"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/session-primer"
RUNTIME_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/session-primer"
RUN_PRIMER="$RUNTIME_DIR/primer.sh"
LOG_FILE="$STATE_DIR/primer.log"
LABEL="com.session-primer"

TOOLS=""
CLAUDE_MODEL=""
INTERVAL=60
DRY_RUN=0

usage() {
    cat <<EOF
Usage: ./install.sh [options]
  --tools "claude codex"        Which CLIs to keep primed (default: auto-detect)
  --claude-model NAME           Model for the claude trigger (default: haiku)
  --interval SECONDS            Tick interval (default: 60)
  --dry-run                     Print what would be installed, change nothing
  -h, --help                    This help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --tools)        TOOLS="${2:-}"; shift ;;
        --claude-model) CLAUDE_MODEL="${2:-}"; shift ;;
        --interval)     INTERVAL="${2:-60}"; shift ;;
        --dry-run)      DRY_RUN=1 ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

[ -x "$PRIMER" ] || { echo "error: $PRIMER not found or not executable" >&2; exit 1; }
case "$INTERVAL" in *[!0-9]*|'') echo "error: --interval must be a number of seconds" >&2; exit 1 ;; esac

# ---- Auto-detect tools -------------------------------------------------------
detected=""
command -v claude >/dev/null 2>&1 && detected="claude"
command -v codex  >/dev/null 2>&1 && detected="$detected codex"
detected=$(echo "$detected" | sed 's/^ //')
[ -n "$detected" ] || { echo "error: neither 'claude' nor 'codex' found on PATH" >&2; exit 1; }

if [ -z "$TOOLS" ] && [ -t 0 ]; then
    printf "Tools to keep primed [%s]: " "$detected"
    read -r TOOLS
fi
[ -n "$TOOLS" ] || TOOLS="$detected"

# ---- Build a PATH that includes the CLIs (launchd/systemd strip your shell PATH)
tool_path="/usr/local/bin:/usr/bin:/bin"
for cli in claude codex; do
    p=$(command -v "$cli" 2>/dev/null) || continue
    d=$(dirname "$p")
    case ":$tool_path:" in *":$d:"*) ;; *) tool_path="$d:$tool_path" ;; esac
done

# ---- Write config -----------------------------------------------------------
conf_content="# session-primer configuration (sourced by primer.sh)
TOOLS=\"$TOOLS\"
CLAUDE_MODEL=\"${CLAUDE_MODEL:-haiku}\"
# CODEX_MODEL=\"\"            # empty = your codex default
# CODEX_EFFORT=\"low\"        # reasoning effort for the codex trigger
# PROMPT=\"Reply with exactly: ok\"
# WINDOW_HOURS=5              # provider window length
# TIMEOUT_SECS=180
# FAIL_RETRY_SECS=600
# RATE_REFRESH_SECS=300         # codex: free usage re-read interval"

# The job runs a COPY of primer.sh from ~/.local/share, not the repo itself:
# on macOS, launchd agents cannot read ~/Documents (TCC privacy protection),
# and this also lets you move or delete the repo without breaking the job.
echo "==> Runtime:    $RUN_PRIMER (copied from repo)"
echo "==> Config:     $CONFIG_FILE"
echo "    Tools:      $TOOLS"
echo "    Tick every: ${INTERVAL}s"
echo "    PATH baked: $tool_path"

if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$RUNTIME_DIR"
    cp "$PRIMER" "$RUN_PRIMER" && chmod +x "$RUN_PRIMER"
    if [ -f "$CONFIG_FILE" ]; then
        echo "    (config exists — leaving it untouched; edit it to change tools/model)"
    else
        printf '%s\n' "$conf_content" > "$CONFIG_FILE"
    fi
fi

# ---- macOS: launchd ---------------------------------------------------------
install_macos() {
    plist="$HOME/Library/LaunchAgents/$LABEL.plist"
    plist_content="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>/bin/sh</string><string>$RUN_PRIMER</string></array>
    <key>RunAtLoad</key><true/>
    <key>StartInterval</key><integer>$INTERVAL</integer>
    <key>EnvironmentVariables</key>
    <dict><key>PATH</key><string>$tool_path</string></dict>
    <key>StandardOutPath</key><string>/dev/null</string>
    <key>StandardErrorPath</key><string>$LOG_FILE</string>
</dict>
</plist>"

    echo "==> launchd:    $plist"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s\n' "$plist_content"
        return 0
    fi
    printf '%s\n' "$plist_content" > "$plist"
    uid=$(id -u)
    launchctl bootout "gui/$uid/$LABEL" 2>/dev/null
    if launchctl bootstrap "gui/$uid" "$plist" 2>/dev/null; then
        echo "==> Loaded. Verify with: launchctl print gui/$uid/$LABEL | head -20"
    else
        launchctl load -w "$plist" && echo "==> Loaded (legacy launchctl load)."
    fi
}

# ---- Linux: systemd user timer, cron fallback -------------------------------
install_linux() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        unit_dir="$HOME/.config/systemd/user"
        service_content="[Unit]
Description=session-primer — keep AI CLI usage windows chained open

[Service]
Type=oneshot
Environment=PATH=$tool_path
ExecStart=/bin/sh $RUN_PRIMER"
        timer_content="[Unit]
Description=session-primer tick

[Timer]
OnBootSec=1min
OnUnitActiveSec=${INTERVAL}s
AccuracySec=15s
Persistent=true

[Install]
WantedBy=timers.target"
        echo "==> systemd:    $unit_dir/session-primer.{service,timer}"
        if [ "$DRY_RUN" -eq 1 ]; then
            printf '%s\n---\n%s\n' "$service_content" "$timer_content"
            return 0
        fi
        mkdir -p "$unit_dir"
        printf '%s\n' "$service_content" > "$unit_dir/session-primer.service"
        printf '%s\n' "$timer_content"   > "$unit_dir/session-primer.timer"
        # Without lingering, a user's systemd instance (and its timers) only
        # runs while that user is logged in — useless on a headless server.
        if loginctl show-user "$USER" 2>/dev/null | grep -q '^Linger=yes'; then
            echo "==> Lingering already enabled for $USER"
        elif loginctl enable-linger "$USER" 2>/dev/null || sudo -n loginctl enable-linger "$USER" 2>/dev/null; then
            echo "==> Enabled lingering for $USER (timer runs even when you are logged out)"
        else
            echo "!!  Could not enable lingering. Run this once, or the timer stops when you log out:"
            echo "    sudo loginctl enable-linger $USER"
        fi
        export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
        systemctl --user daemon-reload
        systemctl --user enable --now session-primer.timer
        echo "==> Enabled. Verify with: systemctl --user list-timers session-primer.timer"
    else
        echo "==> cron fallback (ticks every minute; ignores --interval finer than 60s)"
        cron_line="* * * * * PATH=$tool_path /bin/sh $RUN_PRIMER >/dev/null 2>>$LOG_FILE # session-primer"
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "$cron_line"
            return 0
        fi
        ( crontab -l 2>/dev/null | grep -v '# session-primer$'; echo "$cron_line" ) | crontab -
        echo "==> Installed. Verify with: crontab -l"
    fi
}

# ---- Windows: Task Scheduler, running the script under Git Bash --------------
install_windows() {
    command -v schtasks >/dev/null 2>&1 || { echo "error: schtasks not found — run this from Git Bash on Windows" >&2; exit 1; }
    bash_exe=$(command -v bash)
    if command -v cygpath >/dev/null 2>&1; then
        bash_win=$(cygpath -w "$bash_exe")
        vbs_win=$(cygpath -w "$RUNTIME_DIR/run-hidden.vbs")
    else
        bash_win=$bash_exe
        vbs_win="$RUNTIME_DIR/run-hidden.vbs"
    fi
    # wscript launches bash with window style 0 (hidden), so the tick does not
    # flash a console window every minute. Inside VBScript, quotes are doubled.
    vbs_line1='Set sh = CreateObject("WScript.Shell")'
    vbs_line2="sh.Run \"\"\"$bash_win\"\" -l -c \"\"export PATH='$tool_path:\$PATH'; '$RUN_PRIMER'\"\"\", 0, False"
    task_cmd="wscript.exe \"$vbs_win\""

    mins=$((INTERVAL / 60)); [ "$mins" -lt 1 ] && mins=1
    echo "==> Task Scheduler: task 'session-primer', every $mins minute(s), hidden"
    echo "    launcher: $RUNTIME_DIR/run-hidden.vbs"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s\n%s\n' "$vbs_line1" "$vbs_line2"
        echo "schtasks /Create /F /SC MINUTE /MO 1 /TN session-primer /TR '$task_cmd'"
        return 0
    fi
    printf '%s\r\n%s\r\n' "$vbs_line1" "$vbs_line2" > "$RUNTIME_DIR/run-hidden.vbs"
    # MSYS_NO_PATHCONV stops Git Bash from rewriting /Create-style switches as paths.
    if MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' schtasks /Create /F /SC MINUTE /MO 1 /TN session-primer /TR "$task_cmd" >/dev/null; then
        echo "==> Created. Verify with: schtasks /Query /TN session-primer"
        echo "    The task runs while you are logged in. Keep the machine awake (Settings > Power > Sleep: Never)."
    else
        echo "error: schtasks failed — try running Git Bash as Administrator" >&2
        exit 1
    fi
}

case "$(uname -s)" in
    Darwin)               install_macos ;;
    Linux)                install_linux ;;
    MINGW*|MSYS*|CYGWIN*) install_windows ;;
    *) echo "error: unsupported OS $(uname -s) — schedule '$PRIMER' every minute manually" >&2; exit 1 ;;
esac

[ "$DRY_RUN" -eq 1 ] && echo "==> Dry run: nothing was installed."
echo "==> Check state any time with: $PRIMER --status"
