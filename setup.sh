#!/bin/sh
# session-primer guided setup — one command from a fresh clone.
#
#   1. installs Claude Code and/or Codex CLI if missing
#      (official installers / official release binaries — no Node.js needed)
#   2. signs you in if you are not signed in yet (interactive)
#   3. installs the background daemon (./install.sh)
#
# Works on macOS, Linux (Debian/Ubuntu tested) and Windows via Git Bash.
# Idempotent: re-running skips whatever is already done.
#
# Usage: ./setup.sh [--skip-claude] [--skip-codex] [--no-login] [--no-install] [--no-swap]

set -u

WANT_CLAUDE=1; WANT_CODEX=1; DO_LOGIN=1; DO_INSTALL=1; WANT_SWAP=1
for a in "$@"; do
    case "$a" in
        --skip-claude) WANT_CLAUDE=0 ;;
        --skip-codex)  WANT_CODEX=0 ;;
        --no-login)    DO_LOGIN=0 ;;
        --no-install)  DO_INSTALL=0 ;;
        --no-swap)     WANT_SWAP=0 ;;
        -h|--help)     sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "Unknown option: $a" >&2; exit 2 ;;
    esac
done

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BIN="$HOME/.local/bin"
mkdir -p "$BIN"
export PATH="$BIN:$PATH"
[ -n "${APPDATA:-}" ] && [ -d "$APPDATA/npm" ] && export PATH="$APPDATA/npm:$PATH"

case "$(uname -s)" in
    Darwin)               OS=mac ;;
    Linux)                OS=linux ;;
    MINGW*|MSYS*|CYGWIN*) OS=windows ;;
    *) echo "Unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
    x86_64|amd64)  ARCH=x86_64 ;;
    aarch64|arm64) ARCH=aarch64 ;;
    *) ARCH=unknown ;;
esac

step() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---- swap (tiny Linux VMs) ---------------------------------------------------
if [ "$OS" = linux ] && [ "$WANT_SWAP" -eq 1 ] && [ -r /proc/meminfo ]; then
    mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    if [ "$mem_kb" -lt 2000000 ] && ! swapon --show 2>/dev/null | grep -q . && have sudo; then
        step "Adding a 1 GB swap file (RAM is under 2 GB)"
        if sudo -n true 2>/dev/null || [ -t 0 ]; then
            sudo fallocate -l 1G /swapfile && sudo chmod 600 /swapfile \
              && sudo mkswap /swapfile >/dev/null && sudo swapon /swapfile \
              && { grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null; } \
              && note "done" || note "could not add swap (continuing — it is only a safety margin)"
        else
            note "skipped (needs sudo)"
        fi
    fi
fi

# ---- Claude Code -------------------------------------------------------------
if [ "$WANT_CLAUDE" -eq 1 ]; then
    if have claude; then
        step "Claude Code already installed: $(claude --version 2>/dev/null | head -n 1)"
    else
        step "Installing Claude Code (official installer)"
        case "$OS" in
            windows)
                ps=$(command -v powershell.exe 2>/dev/null || command -v powershell 2>/dev/null || command -v pwsh 2>/dev/null)
                [ -n "$ps" ] || { echo "powershell not found — install Claude Code manually: https://docs.claude.com/en/docs/claude-code/setup" >&2; exit 1; }
                "$ps" -NoProfile -ExecutionPolicy Bypass -Command "irm https://claude.ai/install.ps1 | iex" ;;
            *)  curl -fsSL https://claude.ai/install.sh | bash ;;
        esac
        hash -r 2>/dev/null
        if have claude; then
            note "installed: $(claude --version 2>/dev/null | head -n 1)"
        else
            echo "!!  claude is not on PATH yet. Open a NEW terminal and run ./setup.sh again." >&2
            exit 1
        fi
    fi
fi

# ---- Codex CLI (standalone official release binary) -------------------------
if [ "$WANT_CODEX" -eq 1 ]; then
    if have codex; then
        step "Codex already installed: $(codex --version 2>/dev/null | head -n 1)"
    else
        step "Installing Codex CLI (official release binary, no Node.js needed)"
        case "$OS-$ARCH" in
            linux-x86_64)    triple="x86_64-unknown-linux-musl";  asset="codex-$triple.tar.gz";     inner="codex-$triple" ;;
            linux-aarch64)   triple="aarch64-unknown-linux-musl"; asset="codex-$triple.tar.gz";     inner="codex-$triple" ;;
            mac-x86_64)      triple="x86_64-apple-darwin";        asset="codex-$triple.tar.gz";     inner="codex-$triple" ;;
            mac-aarch64)     triple="aarch64-apple-darwin";       asset="codex-$triple.tar.gz";     inner="codex-$triple" ;;
            windows-x86_64)  triple="x86_64-pc-windows-msvc";     asset="codex-$triple.exe.tar.gz"; inner="codex-$triple.exe" ;;
            windows-aarch64) triple="aarch64-pc-windows-msvc";    asset="codex-$triple.exe.tar.gz"; inner="codex-$triple.exe" ;;
            *) echo "no prebuilt codex for $OS/$ARCH — install manually: npm i -g @openai/codex" >&2; exit 1 ;;
        esac
        auth_hdr=""
        [ -n "${GITHUB_TOKEN:-}" ] && auth_hdr="Authorization: Bearer $GITHUB_TOKEN"
        tag=$(curl -fsSL ${auth_hdr:+-H "$auth_hdr"} https://api.github.com/repos/openai/codex/releases/latest \
              | grep -o '"tag_name": *"[^"]*"' | head -n 1 | cut -d'"' -f4)
        [ -n "$tag" ] || { echo "could not determine the latest codex release (GitHub API)" >&2; exit 1; }
        url="https://github.com/openai/codex/releases/download/$tag/$asset"
        note "$url"
        tmp=$(mktemp -d)
        if curl -fsSL -o "$tmp/codex.tar.gz" "$url" && tar xzf "$tmp/codex.tar.gz" -C "$tmp"; then
            case "$OS" in
                windows) mv "$tmp/$inner" "$BIN/codex.exe" ;;
                *)       mv "$tmp/$inner" "$BIN/codex" && chmod +x "$BIN/codex" ;;
            esac
            rm -rf "$tmp"
            hash -r 2>/dev/null
            note "installed: $(codex --version 2>/dev/null | head -n 1)"
        else
            rm -rf "$tmp"
            echo "download failed — install manually: npm i -g @openai/codex" >&2
            exit 1
        fi
    fi
fi

# ---- PATH for future shells --------------------------------------------------
for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    [ -f "$rc" ] || continue
    grep -q '\.local/bin' "$rc" || printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
done
[ -f "$HOME/.bashrc" ] || [ "$OS" != windows ] || printf 'export PATH="$HOME/.local/bin:$PATH"\n' > "$HOME/.bashrc"

# ---- sign in -----------------------------------------------------------------
claude_signed_in() { claude auth status 2>/dev/null | grep -q '"loggedIn": *true'; }
codex_signed_in()  { codex login status 2>&1 | grep -qi '^logged in'; }

if [ "$DO_LOGIN" -eq 1 ] && [ -t 0 ]; then
    if [ "$WANT_CLAUDE" -eq 1 ] && have claude && ! claude_signed_in; then
        step "Claude Code is not signed in"
        note "Choose the SUBSCRIPTION login (Claude.ai account), not an API key."
        note "If no browser opens, copy the URL it prints to any device and paste the code back here."
        printf '    Sign in now? [Y/n] '; read -r ans
        case "${ans:-Y}" in [Nn]*) ;; *) claude auth login ;; esac
    fi
    if [ "$WANT_CODEX" -eq 1 ] && have codex && ! codex_signed_in; then
        step "Codex is not signed in"
        printf '    Sign in now? [Y/n] '; read -r ans
        case "${ans:-Y}" in
            [Nn]*) ;;
            *)  if [ "$OS" = linux ] && [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
                    note "No desktop detected — using device login: open the URL on any device and enter the code."
                    codex login --device-auth
                else
                    codex login
                fi ;;
        esac
    fi
fi

step "Sign-in status"
if [ "$WANT_CLAUDE" -eq 1 ] && have claude; then
    if claude_signed_in; then note "claude: signed in"; else note "claude: NOT signed in — run: claude auth login"; fi
fi
if [ "$WANT_CODEX" -eq 1 ] && have codex; then
    if codex_signed_in; then note "codex:  signed in"; else note "codex:  NOT signed in — run: codex login   (headless: codex login --device-auth)"; fi
fi

# ---- daemon ------------------------------------------------------------------
if [ "$DO_INSTALL" -eq 1 ]; then
    step "Installing the daemon"
    tools=""
    [ "$WANT_CLAUDE" -eq 1 ] && have claude && tools="claude"
    [ "$WANT_CODEX" -eq 1 ] && have codex && tools="$tools codex"
    tools=$(echo "$tools" | sed 's/^ //')
    [ -n "$tools" ] || { echo "no CLI installed — nothing to prime" >&2; exit 1; }
    exec "$SCRIPT_DIR/install.sh" --tools "$tools" --no-login
else
    step "Done. Install the daemon with: ./install.sh"
fi
