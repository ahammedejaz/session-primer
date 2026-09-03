#!/bin/sh
# session-primer VM bootstrap (Linux, Debian/Ubuntu tested) — installs what the
# daemon needs on a fresh always-on machine:
#   - a 1 GB swap file if the box has < 2 GB RAM and no swap (tiny VMs)
#   - Claude Code (official native installer, no Node required)
#   - Codex CLI (standalone binary from the official GitHub release, no Node)
#   - ~/.local/bin on PATH
# It is idempotent: re-running skips whatever is already in place.
# It does NOT sign in for you — the logins need a browser on another device.
#
# Usage: ./setup-vm.sh [--no-swap] [--skip-codex] [--skip-claude]

set -eu

WANT_SWAP=1; WANT_CODEX=1; WANT_CLAUDE=1
for a in "$@"; do
    case "$a" in
        --no-swap)     WANT_SWAP=0 ;;
        --skip-codex)  WANT_CODEX=0 ;;
        --skip-claude) WANT_CLAUDE=0 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "Unknown option: $a" >&2; exit 2 ;;
    esac
done

[ "$(uname -s)" = Linux ] || { echo "setup-vm.sh is for Linux servers. On macOS just install the CLIs normally."; exit 1; }

BIN="$HOME/.local/bin"
mkdir -p "$BIN"
export PATH="$BIN:$PATH"

step() { printf '\n==> %s\n' "$*"; }

# ---- swap (tiny VMs) ---------------------------------------------------------
if [ "$WANT_SWAP" -eq 1 ]; then
    mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    if [ "$mem_kb" -lt 2000000 ] && ! swapon --show 2>/dev/null | grep -q .; then
        step "Adding a 1 GB swap file (RAM is under 2 GB)"
        sudo fallocate -l 1G /swapfile && sudo chmod 600 /swapfile
        sudo mkswap /swapfile >/dev/null && sudo swapon /swapfile
        grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
    else
        step "Swap: not needed or already present"
    fi
fi

# ---- Claude Code -------------------------------------------------------------
if [ "$WANT_CLAUDE" -eq 1 ]; then
    if command -v claude >/dev/null 2>&1; then
        step "Claude Code already installed: $(claude --version 2>/dev/null)"
    else
        step "Installing Claude Code (official native installer)"
        curl -fsSL https://claude.ai/install.sh | bash
        command -v claude >/dev/null 2>&1 || { echo "claude not on PATH after install — open a new shell and re-run"; exit 1; }
        echo "    installed: $(claude --version)"
    fi
fi

# ---- Codex CLI ---------------------------------------------------------------
if [ "$WANT_CODEX" -eq 1 ]; then
    if command -v codex >/dev/null 2>&1; then
        step "Codex already installed: $(codex --version 2>/dev/null)"
    else
        step "Installing Codex CLI (standalone binary from GitHub releases)"
        case "$(uname -m)" in
            x86_64)          triple="x86_64-unknown-linux-musl" ;;
            aarch64|arm64)   triple="aarch64-unknown-linux-musl" ;;
            *) echo "unsupported architecture $(uname -m) — install codex manually (npm i -g @openai/codex)"; exit 1 ;;
        esac
        tag=$(curl -fsSL https://api.github.com/repos/openai/codex/releases/latest | grep -o '"tag_name": *"[^"]*"' | head -n 1 | cut -d'"' -f4)
        [ -n "$tag" ] || { echo "could not determine latest codex release"; exit 1; }
        url="https://github.com/openai/codex/releases/download/$tag/codex-$triple.tar.gz"
        echo "    $url"
        tmp=$(mktemp -d)
        curl -fsSL -o "$tmp/codex.tar.gz" "$url"
        tar xzf "$tmp/codex.tar.gz" -C "$tmp"
        mv "$tmp/codex-$triple" "$BIN/codex" && chmod +x "$BIN/codex"
        rm -rf "$tmp"
        echo "    installed: $(codex --version)"
    fi
fi

# ---- PATH for future shells --------------------------------------------------
for rc in "$HOME/.bashrc" "$HOME/.profile"; do
    [ -f "$rc" ] || continue
    grep -q '\.local/bin' "$rc" || printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
done

cat <<EOF

==> Done. Next, sign in (each prints a URL to open on your phone or laptop):

    claude auth login            # Claude Code — paste the code it gives you back here
    codex login --device-auth    # Codex — enter the short code on the page

    Verify:  claude auth status     codex login status

    Then install the daemon:  ./install.sh
EOF
