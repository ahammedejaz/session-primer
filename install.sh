#!/bin/sh
# session-primer installer — schedules primer.sh as a once-a-minute tick so
# usage windows chain back-to-back automatically. No times to configure.
#   macOS   : launchd user agent (StartInterval; catches up after sleep)
#   Linux   : systemd user timer (Persistent=true, lingering enabled); cron fallback
#   Windows : Task Scheduler task running the script under Git Bash, hidden
#             (run this from Git Bash)
#
# Usage:
#   ./install.sh                          # auto-detect tools, check sign-in, install
#   ./install.sh --tools "claude codex"   # explicit tool list
#   ./install.sh --dry-run                # show what would be installed
# Flags: --claude-model NAME  --interval SECONDS  --no-login  --no-probe

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PRIMER="$SCRIPT_DIR/primer.sh"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/session-primer"
CONFIG_FILE="$CONFIG_DIR/primer.conf"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/session-primer"
LOG_FILE="$STATE_DIR/primer.log"
RUNTIME_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/session-primer"
RUN_PRIMER="$RUNTIME_DIR/primer.sh"
LABEL="com.session-primer"

# The CLIs usually live here; make sure we can see them even from a fresh shell.
export PATH="$HOME/.local/bin:$PATH"
[ -n "${APPDATA:-}" ] && [ -d "$APPDATA/npm" ] && export PATH="$APPDATA/npm:$PATH"

TOOLS=""
CLAUDE_MODEL=""
INTERVAL=60
DRY_RUN=0
DO_LOGIN=1
DO_PROBE=1

usage() {
    cat <<EOF
Usage: ./install.sh [options]
  --tools "claude codex"        Which CLIs to keep primed (default: auto-detect)
  --claude-model NAME           Model for the claude trigger (default: haiku)
  --interval SECONDS            Tick interval (default: 60)
  --no-login                    Do not offer to sign in interactively
  --no-probe                    Do not run the first tick right away
  --dry-run                     Print what would be installed, change nothing
  -h, --help                    This help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --tools)        TOOLS="${2:-}"; shift ;;
        --claude-model) CLAUDE_MODEL="${2:-}"; shift ;;
        --interval)     INTERVAL="${2:-60}"; shift ;;
        --no-login)     DO_LOGIN=0 ;;
        --no-probe)     DO_PROBE=0 ;;
        --dry-run)      DRY_RUN=1 ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

[ -x "$PRIMER" ] || { echo "error: $PRIMER not found or not executable" >&2; exit 1; }
case "$INTERVAL" in *[!0-9]*|'') echo "error: --interval must be a number of seconds" >&2; exit 1 ;; esac

case "$(uname -s)" in
    Darwin)               OS=mac ;;
    Linux)                OS=linux ;;
    MINGW*|MSYS*|CYGWIN*) OS=windows ;;
    *) echo "error: unsupported OS $(uname -s) — schedule '$PRIMER' every minute manually" >&2; exit 1 ;;
esac

have() { command -v "$1" >/dev/null 2>&1; }
xml_escape() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }
USER_NAME=${USER:-$(id -un)}   # $USER is unset in some containers and minimal images
claude_signed_in() { claude auth status 2>/dev/null | grep -q '"loggedIn": *true'; }
codex_signed_in()  { codex login status 2>&1 | grep -qi '^logged in'; }

# ---- Preflight: which tools, are they installed, are they signed in ---------
detected=""
have claude && detected="claude"
have codex  && detected="$detected codex"
detected=$(echo "$detected" | sed 's/^ //')

if [ -z "$TOOLS" ] && [ -t 0 ]; then
    if [ -n "$detected" ]; then
        printf "Tools to keep primed [%s]: " "$detected"; read -r TOOLS
    fi
fi
[ -n "$TOOLS" ] || TOOLS="$detected"
[ -n "$TOOLS" ] || { echo "error: neither 'claude' nor 'codex' is installed. Run ./setup.sh first." >&2; exit 1; }

echo "==> Preflight"
missing=0
for t in $TOOLS; do
    case "$t" in
        claude|codex) ;;
        *) echo "    $t: unknown tool (expected claude or codex)" >&2; exit 1 ;;
    esac
    if ! have "$t"; then
        echo "    $t: NOT INSTALLED — run ./setup.sh (or install it yourself), then re-run ./install.sh"
        missing=1
        continue
    fi
    if "${t}_signed_in"; then
        echo "    $t: installed, signed in"
    else
        echo "    $t: installed, NOT signed in"
        if [ "$DO_LOGIN" -eq 1 ] && [ -t 0 ] && [ "$DRY_RUN" -eq 0 ]; then
            printf '        Sign in now? [Y/n] '; read -r ans
            case "${ans:-Y}" in
                [Nn]*) ;;
                *) if [ "$t" = claude ]; then
                       claude auth login
                   elif [ "$OS" = linux ] && [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
                       codex login --device-auth
                   else
                       codex login
                   fi ;;
            esac
            if "${t}_signed_in"; then echo "    $t: signed in"; else echo "    $t: still not signed in — the daemon will keep reminding you in its status until you do"; fi
        else
            if [ "$t" = claude ]; then
                echo "        The daemon will report 'trigger FAILED' until you run:  claude auth login"
            else
                echo "        The daemon will report 'usage unreadable' until you run:  codex login   (headless: codex login --device-auth)"
            fi
        fi
    fi
done
[ "$missing" -eq 0 ] || exit 1

# ---- Build a PATH that includes the CLIs (schedulers strip your shell PATH) --
tool_path="/usr/local/bin:/usr/bin:/bin"
for cli in claude codex; do
    p=$(command -v "$cli" 2>/dev/null) || continue
    d=$(dirname "$p")
    case ":$tool_path:" in *":$d:"*) ;; *) tool_path="$d:$tool_path" ;; esac
done

# ---- Config + runtime copy --------------------------------------------------
conf_content="# session-primer configuration (sourced by primer.sh)
TOOLS=\"$TOOLS\"
CLAUDE_MODEL=\"${CLAUDE_MODEL:-haiku}\"
# CODEX_MODEL=\"\"            # empty = your codex default (see README: Codex specifics)
# CODEX_EFFORT=\"low\"        # reasoning effort for the codex trigger
# PROMPT=\"Reply with exactly: ok\"
# WINDOW_HOURS=5              # provider window length
# TIMEOUT_SECS=180
# FAIL_RETRY_SECS=600
# RATE_REFRESH_SECS=300       # codex: free usage re-read interval"

echo "==> Runtime:    $RUN_PRIMER (copy of the repo script; the job runs this)"
echo "==> Config:     $CONFIG_FILE"
echo "    Tools:      $TOOLS"
echo "    Tick every: ${INTERVAL}s"
echo "    PATH baked: $tool_path"

if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$RUNTIME_DIR"
    cp "$PRIMER" "$RUN_PRIMER" && chmod +x "$RUN_PRIMER"
    echo "$INTERVAL" > "$STATE_DIR/tick-interval"   # primer.sh: heartbeat is stale after 3 missed ticks
    if [ -f "$CONFIG_FILE" ]; then
        echo "    (config exists — leaving it untouched; edit it to change tools/model)"
    else
        printf '%s\n' "$conf_content" > "$CONFIG_FILE"
    fi
fi

# ---- macOS: launchd ---------------------------------------------------------
install_mac() {
    plist="$HOME/Library/LaunchAgents/$LABEL.plist"
    plist_content="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>/bin/sh</string><string>$(xml_escape "$RUN_PRIMER")</string></array>
    <key>RunAtLoad</key><true/>
    <key>StartInterval</key><integer>$INTERVAL</integer>
    <key>EnvironmentVariables</key>
    <dict><key>PATH</key><string>$(xml_escape "$tool_path")</string></dict>
    <key>StandardOutPath</key><string>/dev/null</string>
    <key>StandardErrorPath</key><string>$(xml_escape "$LOG_FILE")</string>
</dict>
</plist>"
    echo "==> launchd:    $plist"
    if [ "$DRY_RUN" -eq 1 ]; then printf '%s\n' "$plist_content"; return 0; fi
    mkdir -p "$HOME/Library/LaunchAgents"
    printf '%s\n' "$plist_content" > "$plist"
    uid=$(id -u)
    launchctl bootout "gui/$uid/$LABEL" 2>/dev/null
    if launchctl bootstrap "gui/$uid" "$plist" 2>/dev/null; then
        echo "==> Loaded (launchctl bootstrap)."
    elif launchctl load -w "$plist" 2>/dev/null; then
        echo "==> Loaded (launchctl load)."
    else
        echo "error: launchctl could not load the agent. Try logging out and back in, then re-run ./install.sh" >&2
        exit 1
    fi
}

# ---- Linux: systemd user timer, cron fallback -------------------------------
install_linux() {
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    if have systemctl && [ -d /run/systemd/system ] && systemctl --user show-environment >/dev/null 2>&1; then
        unit_dir="$HOME/.config/systemd/user"
        service_content="[Unit]
Description=session-primer — keep AI CLI usage windows chained open

[Service]
Type=oneshot
Environment=\"PATH=$tool_path\"
ExecStart=/bin/sh \"$RUN_PRIMER\""
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
        if [ "$DRY_RUN" -eq 1 ]; then printf '%s\n---\n%s\n' "$service_content" "$timer_content"; return 0; fi
        mkdir -p "$unit_dir"
        printf '%s\n' "$service_content" > "$unit_dir/session-primer.service"
        printf '%s\n' "$timer_content"   > "$unit_dir/session-primer.timer"
        # Without lingering, a user's systemd instance (and its timers) only runs
        # while that user is logged in — useless on a headless server.
        if loginctl show-user "$USER_NAME" 2>/dev/null | grep -q '^Linger=yes'; then
            echo "==> Lingering already enabled for $USER_NAME"
        elif loginctl enable-linger "$USER_NAME" 2>/dev/null || sudo -n loginctl enable-linger "$USER_NAME" 2>/dev/null; then
            echo "==> Enabled lingering for $USER_NAME (timer runs even when you are logged out)"
        else
            echo "!!  Could not enable lingering. Run this once, or the timer stops when you log out:"
            echo "    sudo loginctl enable-linger $USER_NAME"
        fi
        systemctl --user daemon-reload
        systemctl --user enable --now session-primer.timer
        echo "==> Enabled. Verify with: systemctl --user list-timers session-primer.timer"
    else
        have crontab || { echo "error: neither a usable systemd user session nor crontab found" >&2; exit 1; }
        echo "==> cron:       every minute (systemd user session not available here)"
        cron_line="* * * * * PATH='$tool_path' /bin/sh '$RUN_PRIMER' >/dev/null 2>>'$LOG_FILE' # session-primer"
        if [ "$DRY_RUN" -eq 1 ]; then echo "$cron_line"; return 0; fi
        ( crontab -l 2>/dev/null | grep -v '# session-primer$'; echo "$cron_line" ) | crontab -
        echo "==> Installed. Verify with: crontab -l"
    fi
}

# ---- Windows: Task Scheduler via PowerShell, running the script under Git Bash
install_windows() {
    ps=$(command -v powershell.exe 2>/dev/null || command -v powershell 2>/dev/null || command -v pwsh 2>/dev/null)
    [ -n "$ps" ] || { echo "error: PowerShell not found — run this from Git Bash on Windows" >&2; exit 1; }
    have cygpath || { echo "error: cygpath not found — run this from Git Bash (Git for Windows)" >&2; exit 1; }
    bash_win=$(cygpath -w "$(command -v bash)")
    vbs="$RUNTIME_DIR/run-hidden.vbs";      vbs_win=$(cygpath -w "$vbs")
    ps1="$RUNTIME_DIR/register-task.ps1";   ps1_win=$(cygpath -w "$ps1")
    mins=$((INTERVAL / 60)); [ "$mins" -lt 1 ] && mins=1

    # wscript launches Git Bash with window style 0 (hidden), so the tick never
    # flashes a console window. Inside a VBScript string, quotes are doubled.
    vbs1='Set sh = CreateObject("WScript.Shell")'
    # \$PATH must reach bash unexpanded so the launcher appends the user's PATH at run time.
    inner="export PATH='$tool_path:\$PATH'; '$RUN_PRIMER'"
    vbs2="sh.Run \"\"\"$bash_win\"\" -l -c \"\"$inner\"\"\", 0, False"

    # Register-ScheduledTask instead of schtasks: lets us allow running on
    # battery (schtasks defaults to AC-only, which silently stops laptops).
    ps_content="\$ErrorActionPreference = 'Stop'
\$action   = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument '\"$vbs_win\"'
\$trigger  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(30) -RepetitionInterval (New-TimeSpan -Minutes $mins) -RepetitionDuration (New-TimeSpan -Days 3650)
\$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName 'session-primer' -Action \$action -Trigger \$trigger -Settings \$settings -Description 'session-primer: keeps AI coding CLI usage windows chained open' -Force | Out-Null
Write-Output 'registered'"

    echo "==> Task Scheduler: task 'session-primer', every $mins minute(s), hidden, allowed on battery"
    echo "    launcher:   $vbs"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s\n%s\n---\n%s\n' "$vbs1" "$vbs2" "$ps_content"
        return 0
    fi
    printf '%s\r\n%s\r\n' "$vbs1" "$vbs2" > "$vbs"
    printf '%s\r\n' "$ps_content" > "$ps1"
    if out=$("$ps" -NoProfile -ExecutionPolicy Bypass -File "$ps1_win" 2>&1) && printf '%s' "$out" | grep -q registered; then
        echo "==> Registered. Verify with: schtasks /Query /TN session-primer"
        echo "    Runs while you are logged in. Keep the PC awake: Settings > System > Power > Sleep: Never."
    else
        echo "error: could not register the task:" >&2
        printf '%s\n' "$out" >&2
        echo "Try again from a Git Bash started with 'Run as administrator'." >&2
        exit 1
    fi
}

case "$OS" in
    mac)     install_mac ;;
    linux)   install_linux ;;
    windows) install_windows ;;
esac

if [ "$DRY_RUN" -eq 1 ]; then
    echo "==> Dry run: nothing was installed."
    exit 0
fi

# ---- First probe + status, so you see it working right away -----------------
if [ "$DO_PROBE" -eq 1 ]; then
    echo "==> Sending the first probe to learn your current windows (takes a few seconds)..."
    PATH="$tool_path:$PATH" "$RUN_PRIMER" || true
    echo
    "$RUN_PRIMER" --status
fi
cat <<EOF

==> Done. The daemon now ticks every ${INTERVAL}s in the background.
    Check any time:   $PRIMER --status      (or --watch for the live dashboard)
    Self-diagnose:    $PRIMER --doctor
    Remember: the machine must stay on and awake for the chain to keep going.
EOF
