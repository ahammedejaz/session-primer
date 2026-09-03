#!/bin/sh
# session-primer uninstaller — removes the scheduled job.
# Pass --purge to also delete config, state and logs.

set -u
LABEL="com.session-primer"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/session-primer"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/session-primer"
RUNTIME_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/session-primer"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

case "$(uname -s)" in
    Darwin)
        plist="$HOME/Library/LaunchAgents/$LABEL.plist"
        launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
        [ -f "$plist" ] && rm "$plist" && echo "Removed $plist"
        ;;
    Linux)
        if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
            systemctl --user disable --now session-primer.timer 2>/dev/null
            rm -f "$HOME/.config/systemd/user/session-primer.service" \
                  "$HOME/.config/systemd/user/session-primer.timer"
            systemctl --user daemon-reload
            echo "Removed systemd user units"
        fi
        if crontab -l 2>/dev/null | grep -q '# session-primer$'; then
            crontab -l 2>/dev/null | grep -v '# session-primer$' | crontab -
            echo "Removed crontab entries"
        fi
        ;;
esac

rm -rf "$RUNTIME_DIR" && echo "Removed runtime copy $RUNTIME_DIR"

if [ "$PURGE" -eq 1 ]; then
    rm -rf "$CONFIG_DIR" "$STATE_DIR"
    echo "Purged $CONFIG_DIR and $STATE_DIR"
else
    echo "Config and logs kept in $CONFIG_DIR and $STATE_DIR (use --purge to delete)"
fi
echo "session-primer unscheduled."
