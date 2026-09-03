# session-primer

Keep your AI coding CLI's **5-hour usage window** permanently chained open, so the next reset is never more than 5 hours away — and never lands in the middle of your deepest task.

Works with **Claude Code** (`claude`) and **OpenAI Codex CLI** (`codex`). Runs on a free always-on VM, or on your own Mac, Windows or Linux machine. Zero dependencies beyond the CLIs you already have.

```
 windows chain forever, with no human involved:
 |─── W1 ────|─── W2 ────|─── W3 ────|─── W4 ────|
 ^ trigger    ^ trigger   ^ your work ^ trigger
              (you sleep)   counts here, resets on schedule
```

## Contents

1. [The problem](#the-problem)
2. [What it does — and does not do](#what-it-does--and-does-not-do)
3. [How it works](#how-it-works)
4. [Choose where to run it](#choose-where-to-run-it) ← **read the 24/7 warning**
5. [Setup A — Free always-on VM (recommended)](#setup-a--free-always-on-vm-recommended)
6. [Setup B — Your own Mac](#setup-b--your-own-mac)
7. [Setup C — Your own Windows PC](#setup-c--your-own-windows-pc)
8. [Setup D — Your own Linux machine](#setup-d--your-own-linux-machine)
9. [Verify it is working](#verify-it-is-working)
10. [Day-to-day commands](#day-to-day-commands)
11. [Configuration reference](#configuration-reference)
12. [Codex specifics](#codex-specifics)
13. [Troubleshooting](#troubleshooting)
14. [Security and privacy](#security-and-privacy)
15. [FAQ](#faq)
16. [License](#license)

---

## The problem

Claude Code and Codex subscriptions meter usage in rolling **5-hour windows anchored to your first message**. Start working at 9:00 AM and your window runs 9:00 → 14:00. Heavy usage (max reasoning effort, big contexts, subagents) can exhaust it by 11:00, leaving you locked out until 14:00 with the day's work half done.

The window is anchored to *any* message — including one sent by a script at 4:00 AM while you sleep. session-primer exploits exactly that: it keeps a window ticking at all times, so when you sit down, one is already partly elapsed and the reset is close.

## What it does — and does not do

**Does:**
- Sends one trivial, nearly-free prompt (`"Reply with exactly: ok"` on the cheapest model) each time a 5-hour window expires, which starts the next one immediately.
- Reads the provider's **own** reset time after each trigger, so it always knows exactly when the next one is due. Nothing is estimated.
- Runs unattended from a 60-second timer, survives reboots, and shows you what it is doing (`--status`, a live `--watch` dashboard, and a log).
- Costs about 5 tiny prompts per day per tool.

**Does not:**
- **Give you more quota.** Max/Pro/Plus plans have separate weekly caps that reset on a fixed schedule regardless of session windows. This only shifts *when* 5-hour resets land.
- **Work while the machine running it is asleep or off.** See [Choose where to run it](#choose-where-to-run-it).
- Touch your credentials or send them anywhere. It runs the official CLIs on a machine *you* signed in on. There is no service, no server, no account — see [Security and privacy](#security-and-privacy).

**Terms-of-service note.** Anthropic's and OpenAI's limits language assumes "ordinary usage." Timing your own single account's windows is not explicitly prohibited, but not explicitly blessed either. Use your judgment; never combine this with credential sharing or multi-account schemes.

## How it works

A scheduler (launchd on macOS, a systemd user timer on Linux, Task Scheduler on Windows, cron as fallback) runs `primer.sh` once a minute. Each run is a "tick":

**Claude Code**
1. If the tracked window is still open → do nothing (silent, free).
2. If it has expired, or nothing is tracked yet → send the trigger from an empty directory with MCP servers, project settings and session persistence disabled, using `--output-format stream-json`.
3. Claude Code's response includes a `rate_limit_event` carrying Anthropic's own view of your windows: the exact `resetsAt` of the 5-hour window, its utilization, and the 7-day window. That reset time becomes the next trigger time.
4. If the window is ever *exhausted*, the rejected response still carries the reset time, and the daemon fires right after it.

**Codex**
1. Every 5 minutes, read `account/rateLimits/read` from the Codex app-server over stdio JSON-RPC. This returns the provider's windows (`usedPercent`, duration, `resetsAt`, plan type) and **costs no quota**.
2. If a 5-hour window is open — whether the daemon started it or you did — adopt its exact reset time.
3. Only when no 5-hour window exists, send a trigger, then read again.
4. Two non-primeable states are detected and shown rather than failing silently: *not signed in*, and *plan has no 5-hour window* (free ChatGPT plans only have a monthly window).

**Both:** state lives in `~/.local/state/session-primer/` (one `window-end-<tool>` file per tool, plus provider usage snapshots). Failed triggers (expired login, offline) are logged and retried with a 10-minute backoff. A lock prevents overlapping ticks. The first tick after install sends one probe per tool so tracking is exact from the first minute, even if a window was already open.

---

## Choose where to run it

> ### ⚠️ The machine running session-primer must be on and awake 24/7
>
> The trigger has to be sent by something signed in to your account **at the exact moment a window expires** — typically at night. Nothing can be sent from a laptop that is asleep, shut down, or has its lid closed.
>
> If the machine was off or asleep at a boundary, **nothing breaks — but nothing was primed either.** When it comes back, the daemon simply starts fresh: it probes the provider, adopts whatever window exists, and resumes chaining from that moment. The first window after a downtime is anchored at wake-up time, exactly as if you had typed the first message yourself. You only get the benefit for boundaries the machine was awake for.
>
> A laptop that sleeps overnight therefore gives you the benefit **during your working day only** (lunch breaks, meetings), never for the morning window. For the full effect, run it on something that never sleeps.

| Where | Runs 24/7? | Effort | Notes |
|---|---|---|---|
| **A. Free always-on VM** (Oracle Cloud Always Free) | Yes | 20 minutes once | Recommended. Covers every device on your account. See [Setup A](#setup-a--free-always-on-vm-recommended) |
| **B. Your Mac** | Only if you keep it awake | 5 minutes | Plugged in + sleep disabled, or scheduled wake. See [Setup B](#setup-b--your-own-mac) |
| **C. Your Windows PC** | Only if you keep it awake | 5 minutes | Plugged in + sleep set to Never. See [Setup C](#setup-c--your-own-windows-pc) |
| **D. Your Linux machine** | Only if you keep it awake | 5 minutes | Same steps as the VM. See [Setup D](#setup-d--your-own-linux-machine) |

Usage windows are **account-wide**, not per-machine: one daemon on one machine serves your laptop, your other laptop and your phone. Run **one daemon per account**. Two do not conflict — each adopts the provider's real reset time — but the second one's triggers are wasted.

---

## Setup A — Free always-on VM (recommended)

Any Linux box works (a Raspberry Pi, an old laptop, any VPS). These steps use Oracle Cloud's Always Free tier because it costs nothing indefinitely. Running your own CLIs, signed in by you, on a server you control is entirely legitimate — people run Claude Code on servers all the time.

### Step 1 — Get a free VM on Oracle Cloud

1. Go to [cloud.oracle.com/free](https://www.oracle.com/cloud/free/) and sign up. A credit/debit card is required for identity verification (a small temporary hold, not a charge); Always-Free usage is never billed unless you deliberately create paid resources. **Choose your home region carefully — it cannot be changed later.**
2. In the console: **Compute → Instances → Create instance**.
   - Image: **Ubuntu 22.04 or 24.04** (20.04 also works).
   - Shape: **VM.Standard.A1.Flex** (ARM, 1 OCPU / 6 GB is plenty) or **VM.Standard.E2.1.Micro** (x86, 1 GB RAM — also fine; this daemon needs almost nothing). If A1 says *out of capacity*, take the Micro or try again later.
   - Networking: keep the defaults (a public IPv4 is assigned).
   - **Add your SSH public key** (`~/.ssh/id_ed25519.pub` on your laptop; create one with `ssh-keygen -t ed25519` if you have none).
3. Note the instance's **public IP** once it is running.

Two Oracle caveats worth knowing:
- **Idle reclamation.** Oracle may *stop* an Always-Free instance that stays idle for 7 days (CPU under 20%, network under 20%). This daemon is very idle. If that happens the instance is stopped, not deleted: open the console, start it, and the chain resumes automatically. Many users report that upgrading the account to Pay-As-You-Go (still $0 for the free shapes) exempts you; Oracle's docs are ambiguous, so treat that as likely rather than guaranteed.
- **Card verification** occasionally rejects some cards; try another.

### Step 2 — Connect over SSH

Add an alias on your laptop so `ssh oci` just works:

```sh
cat >> ~/.ssh/config <<'EOF'
Host oci
    HostName <PUBLIC-IP>
    User ubuntu
    IdentityFile ~/.ssh/id_ed25519
EOF
ssh oci
```

(Oracle's Ubuntu images use the user `ubuntu`, which has passwordless `sudo`.)

### Step 3 — Clone and bootstrap

On the VM:

```sh
sudo timedatectl set-timezone Asia/Kolkata     # your timezone — so logs and the dashboard show local time
git clone https://github.com/ahammedejaz/session-primer.git
cd session-primer
./setup-vm.sh
```

`setup-vm.sh` is idempotent and does four things:
- adds a 1 GB swap file if the VM has under 2 GB RAM and no swap (Micro shapes);
- installs **Claude Code** with Anthropic's official native installer (`curl -fsSL https://claude.ai/install.sh | bash`, no Node.js needed);
- installs **Codex CLI** as a standalone binary from OpenAI's official GitHub release for your CPU architecture (no Node.js needed);
- puts `~/.local/bin` on your PATH for future shells.

Skip a CLI you do not use with `--skip-codex` or `--skip-claude`. Open a new shell afterwards (or `source ~/.bashrc`) so `claude` and `codex` are on PATH.

### Step 4 — Sign in to Claude and Codex

Both CLIs support signing in on a machine with no browser: they print a URL you open on your phone or laptop.

```sh
claude auth login
```
Choose the subscription login (not an API key — API keys are pay-per-token and have no 5-hour window, which defeats the purpose). Open the printed URL on any device, sign in, and **paste the code it gives you back into the VM terminal**. Verify with `claude auth status` — you want `"loggedIn": true` and your `subscriptionType`.

```sh
codex login --device-auth
```
Open the URL, enter the short code shown, approve. Verify with `codex login status`.

Only have one of the two? Sign in to that one; the daemon handles a missing or unsigned tool gracefully (see [Codex specifics](#codex-specifics)).

### Step 5 — Install the daemon

```sh
./install.sh --tools "claude codex"      # or just "claude"
```

What it does:
- writes `~/.config/session-primer/primer.conf` (tools, models — editable any time; never overwritten);
- copies `primer.sh` to `~/.local/share/session-primer/` and runs the daemon from there, so you can move or delete the clone without breaking it;
- creates a **systemd user timer** (`session-primer.timer`, every 60 s, `Persistent=true` so a missed tick runs after a reboot) with the CLI locations baked into its PATH;
- enables **lingering** for your user (`loginctl enable-linger`) — essential on a server: without it, user timers only run while you are logged in over SSH.

If you use Codex with a ChatGPT-account login, set the trigger model now (see [Codex specifics](#codex-specifics) for why):

```sh
nano ~/.config/session-primer/primer.conf     # CODEX_MODEL="gpt-5.4-mini"  CODEX_EFFORT="low"
```

Then jump to [Verify it is working](#verify-it-is-working). From your laptop, at any time:

```sh
ssh oci ~/session-primer/primer.sh --status          # one-shot
ssh -t oci ~/session-primer/primer.sh --watch        # live dashboard (ctrl+c exits)
```

---

## Setup B — Your own Mac

Read the [24/7 warning](#choose-where-to-run-it) first. On a Mac the daemon runs as a launchd user agent; it starts at login and ticks every minute, but **pauses whenever the Mac sleeps**.

### 1. Install the CLIs you use

```sh
curl -fsSL https://claude.ai/install.sh | bash     # Claude Code (official installer)
npm install -g @openai/codex                       # Codex (needs Node.js; or: brew install codex)
```

### 2. Sign in

```sh
claude auth login      # opens your browser; choose the subscription login, not an API key
codex login            # opens your browser
```

Verify with `claude auth status` and `codex login status`.

### 3. Clone and install

```sh
git clone https://github.com/ahammedejaz/session-primer.git
cd session-primer
./install.sh                     # auto-detects which CLIs you have; or --tools "claude"
```

This creates `~/Library/LaunchAgents/com.session-primer.plist` (60-second `StartInterval`, starts at login) and runs a copy of the script from `~/.local/share/session-primer/`. The copy matters: launchd agents cannot read `~/Documents` (macOS privacy protection), so a job pointing into a clone under Documents fails with "Operation not permitted". The installer also bakes the CLI locations into the job's PATH, because launchd does not use your shell's PATH.

Using Codex with a ChatGPT-account login? Set `CODEX_MODEL` in `~/.config/session-primer/primer.conf` — see [Codex specifics](#codex-specifics).

### 4. Keep the Mac awake — this is the whole game

Pick one:

- **Plugged in, lid open, screen off:** *System Settings → Battery → Options → "Prevent automatic sleeping on power adapter when the display is off"* → on. The daemon then ticks all night. A closed lid still sleeps a MacBook unless it is in clamshell mode (external display + power).
- **Scheduled wake:** `sudo pmset repeat wakeorpoweron MTWRFSU 04:00:00` wakes the Mac at 4:00 every day; the tick fires within a minute, and the Mac dozes off again. Combined with the chain, this reproduces a fixed "4 AM trigger" plus normal chaining while you work. Needs power connected.
- **Temporary:** `caffeinate -s` in a terminal keeps the Mac awake while plugged in until you close it.

Without one of these, expect the chain to pause overnight and restart fresh when you open the lid — no harm, no morning benefit.

Then go to [Verify it is working](#verify-it-is-working).

---

## Setup C — Your own Windows PC

Read the [24/7 warning](#choose-where-to-run-it) first. On Windows the daemon runs as a **Task Scheduler** task that starts the script every minute under **Git Bash**, hidden (no console window flashing).

> **Status:** the Windows path was written carefully but has **not yet been verified on a real Windows machine by the author**. If you try it, please open an issue with what happened — including "it just worked".

### 1. Prerequisites

- **Git for Windows** — [git-scm.com/download/win](https://git-scm.com/download/win). This provides **Git Bash**, which runs the scripts. Claude Code on Windows requires it anyway.
- **Node.js** (LTS) — only if you want Codex, which installs through npm.

### 2. Install the CLIs you use

In **PowerShell**:

```powershell
irm https://claude.ai/install.ps1 | iex        # Claude Code (official installer)
npm install -g @openai/codex                   # Codex
```

Close and reopen your terminal so the new commands are on PATH.

### 3. Sign in

```powershell
claude auth login      # opens your browser; choose the subscription login, not an API key
codex login            # opens your browser
```

Verify with `claude auth status` and `codex login status`.

### 4. Clone and install — from Git Bash

Open **Git Bash** (Start menu → "Git Bash"), then:

```sh
git clone https://github.com/ahammedejaz/session-primer.git
cd session-primer
./install.sh                     # auto-detects which CLIs you have; or --tools "claude"
```

This copies the script to `~/.local/share/session-primer/`, writes a tiny `run-hidden.vbs` launcher there, and registers a Task Scheduler task named `session-primer` that runs the launcher every minute. The launcher starts Git Bash invisibly with the CLI locations on PATH. The task runs **while you are logged in** (no password storage needed). If `schtasks` is refused, run Git Bash as Administrator once.

Using Codex with a ChatGPT-account login? Set `CODEX_MODEL` in `~/.config/session-primer/primer.conf` — see [Codex specifics](#codex-specifics).

### 5. Keep the PC awake — this is the whole game

*Settings → System → Power & battery → Screen, sleep & hibernate timeouts* → set **"Make my device sleep after"** to **Never** when plugged in (screen off is fine). Closing a laptop lid usually sleeps it: *Control Panel → Power Options → Choose what closing the lid does* → **Do nothing** when plugged in.

Without this, the chain pauses whenever the PC sleeps and restarts fresh when it wakes.

### 6. Verify

In Git Bash: `./primer.sh --status`. In PowerShell or cmd: `schtasks /Query /TN session-primer` should show the task with a next run time about a minute away. Then see [Verify it is working](#verify-it-is-working).

**Alternative:** if you already use WSL2, the Linux instructions (Setup D) work inside it, but WSL's own lifecycle (it stops when idle) makes the Git Bash route more reliable.

---

## Setup D — Your own Linux machine

Read the [24/7 warning](#choose-where-to-run-it) first. Then follow [Setup A, Steps 3–5](#step-3--clone-and-bootstrap) on the machine itself (skip the timezone command if it is already right). `setup-vm.sh` works on any Debian/Ubuntu-style desktop; on other distributions install the two CLIs by hand first. Disable suspend in your desktop's power settings (or `sudo systemctl mask sleep.target suspend.target`).

---

## Verify it is working

```sh
./primer.sh --status
```

Within a minute of install the first tick sends one probe per tool, and you should see something like:

```
claude: window OPEN until 2026-09-03 21:20 (4h 11m left) — next trigger at expiry
        5h used 14% · weekly used 6% (resets 2026-09-09 23:30) · provider data from 16:56
codex:  window OPEN until 2026-09-03 21:35 (4h 26m left) — next trigger at expiry
        5h used 3% · weekly used 1% (resets 2026-09-10 09:00) · provider data from 17:08

Last log entries:
2026-09-03 16:56:31 claude: trigger OK — provider says window resets 2026-09-03 21:20 (5h used 14%, weekly 6%)
```

Cross-check against the source of truth: in Claude Code run `/usage` — the 5-hour reset time should match what the daemon reports, to the minute.

Confirm the scheduler itself:

| Platform | Command | Healthy output |
|---|---|---|
| Linux | `systemctl --user list-timers session-primer.timer` | `NEXT` about a minute away, `LAST` about a minute ago |
| macOS | `launchctl print gui/$(id -u)/com.session-primer \| grep -E 'runs\|last exit'` | `last exit code = 0`, `runs` increasing |
| Windows | `schtasks /Query /TN session-primer` | Status `Ready`, next run time about a minute away |

Then leave it alone. The proof comes at the first expiry: the log gains a `trigger OK — provider says window resets …` line five hours later, for a message you never typed. `./primer.sh --watch` shows it live.

---

## Day-to-day commands

All from the clone directory (or `~/.local/share/session-primer/primer.sh`, the running copy):

```sh
./primer.sh --status              # window state per tool, provider usage, recent log
./primer.sh --watch               # live dashboard: bars, countdowns, daemon health (ctrl+c exits)
./primer.sh --dry-run             # what the next tick would do, sending nothing
./primer.sh --sync                # re-check the provider now (claude: one tiny probe; codex: free read)
./primer.sh --set-end codex 21:20 # manual override of a tracked window end (rarely needed)
tail -f ~/.local/state/session-primer/primer.log   # watch events as they happen
```

The log records only events — triggers, probes, adopted windows, failures. Silent ticks are not logged, so a quiet log during an open window is normal.

**Changing settings:** edit `~/.config/session-primer/primer.conf`; it takes effect on the next tick. No reinstall needed. Re-run `./install.sh` only after pulling a new version of the scripts (it refreshes the running copy).

**Updating:** `git pull && ./install.sh`.

**Uninstall:**

```sh
./uninstall.sh            # remove the scheduled job and the running copy; keep config and logs
./uninstall.sh --purge    # remove everything
```

## Configuration reference

`~/.config/session-primer/primer.conf` — plain shell variable assignments (see `primer.conf.example`):

| Variable | Default | Meaning |
|---|---|---|
| `TOOLS` | `"claude"` | Space-separated tools to prime: `claude`, `codex` |
| `PROMPT` | `"Reply with exactly: ok"` | The trigger message. Keep it trivial |
| `CLAUDE_MODEL` | `"haiku"` | Model for the Claude trigger; haiku is the cheapest |
| `CODEX_MODEL` | `""` (codex default) | Model for the Codex trigger — see Codex specifics |
| `CODEX_EFFORT` | `"low"` | Reasoning effort for the Codex trigger (`minimal` conflicts with web search on some configs) |
| `WINDOW_HOURS` | `5` | Provider window length, if it ever changes |
| `TIMEOUT_SECS` | `180` | Kill a hung trigger after this long |
| `FAIL_RETRY_SECS` | `600` | Backoff after a failed trigger or unreadable usage |
| `RATE_REFRESH_SECS` | `300` | Codex: how often to re-read provider usage (free) |

Files: state in `~/.local/state/session-primer/` (`window-end-*`, `rate-*`, `codex-state`, `last-*.out` raw outputs, `primer.log`); the running script in `~/.local/share/session-primer/`. Both honor `XDG_STATE_HOME` / `XDG_DATA_HOME` / `XDG_CONFIG_HOME`.

## Codex specifics

- **Plan requirement.** The 5-hour window exists on paid ChatGPT plans (Plus, Pro, Team…). A free ChatGPT login has only a monthly window; the daemon detects this and shows `signed in (plan: free) — this plan has no 5-hour window, nothing to prime`. Upgrade later and it picks the window up on its own within `RATE_REFRESH_SECS`, no config change.
- **Not signed in yet?** The daemon shows `usage unreadable (codex account authentication required…) — sign in here with: codex login --device-auth` and retries every 10 minutes. Sign in whenever; run `./primer.sh --sync` to skip the wait.
- **Model restrictions with ChatGPT-account auth.** Codex rejects some models for ChatGPT logins (`The 'X' model is not supported when using Codex with a ChatGPT account`) — including some defaults set in `~/.codex/config.toml`. Set `CODEX_MODEL` to a small model your account lists; the account's valid model slugs are cached in `~/.codex/models_cache.json` (`grep -o '"slug":"[^"]*"' ~/.codex/models_cache.json`). `gpt-5.4-mini` worked at the time of writing.
- **Effort.** `CODEX_EFFORT="low"` keeps the trigger cheap. `minimal` fails if your Codex config enables the `web_search` tool.
- **Cost.** Codex's own system prompt makes even a trivial turn ~10k tokens; still a rounding error against a 5-hour window.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `trigger FAILED` in the log; `last-claude.out` mentions authentication | Login expired (password change, "sign out everywhere", token revoked) | `claude auth login` on that machine; the next tick recovers |
| `codex: cannot read usage — … authentication required` | Codex not signed in on this machine | `codex login --device-auth` (or `codex login` on a desktop), then `./primer.sh --sync` |
| `codex: … this plan has no 5-hour window` | Free ChatGPT plan | Nothing to fix; upgrade when you want Codex primed |
| Codex: `model is not supported when using Codex with a ChatGPT account` | Trigger model not allowed for your login | Set `CODEX_MODEL` per Codex specifics above |
| Chain "restarts fresh" every morning | The machine slept or was off overnight — expected | Keep it awake (see your Setup section) or move to a VM |
| Linux: `window EXPIRED` persists; timer `NEXT` shows `n/a` | Timer not running — usually lingering is off or a reboot before it was enabled | `sudo loginctl enable-linger $USER`, then `./install.sh` |
| Linux: `systemctl --user` says "Failed to connect to bus" over SSH | Missing runtime dir in a non-login shell | `export XDG_RUNTIME_DIR=/run/user/$(id -u)` |
| macOS: `/bin/sh: … primer.sh: Operation not permitted` | The job points at a script inside `~/Documents` (privacy-protected) | Re-run `./install.sh` — current versions run a copy from `~/.local/share` |
| macOS: `claude: CLI not found on PATH` in the log | launchd's minimal PATH | Re-run `./install.sh`; it bakes the CLI locations into the plist |
| Windows: `schtasks` access denied during install | Task creation refused for the current user | Run Git Bash as Administrator once, re-run `./install.sh` |
| Windows: task exists but nothing ever happens | Git Bash path or PATH inside the hidden launcher is wrong | Run `~/.local/share/session-primer/primer.sh` from Git Bash by hand and read the error; then open an issue |
| Oracle instance stopped by itself | Idle reclamation | Start it from the Oracle console; consider upgrading to Pay-As-You-Go |
| `--status` disagrees with `/usage` | Should not happen after the first probe; possible right after a long outage | `./primer.sh --sync` |
| Log shows `no rate_limit_event in response` | Claude Code changed its stream-json output | Daemon falls back to "trigger time + 5h"; please open an issue |

Raw outputs of the last trigger per tool are kept in `~/.local/state/session-primer/last-<tool>.out` for diagnosis.

## Security and privacy

- **Your credentials never leave your machine.** session-primer runs the official `claude` and `codex` binaries under your own login on a machine you signed in on. It has no server component, no accounts, no telemetry, and makes no network requests of its own.
- Do **not** turn this into a hosted service that takes other people's logins. That means holding OAuth tokens with full access to their accounts, it violates both providers' terms (credential sharing; subscription OAuth is restricted to the providers' own clients), and a datacenter IP firing prompts across many accounts is exactly what anti-abuse systems flag — the users get banned. Everyone should run their own copy.
- The trigger runs from an empty directory with MCP servers and project settings disabled, so it cannot see or touch any of your projects.
- On a VM, keep the SSH key safe: whoever can log into the VM can use your CLI logins.

## FAQ

**Do I need Claude Code or Codex open in a terminal?** No. The daemon spawns a short-lived headless process (`claude -p …`) that sends one message and exits. Nothing visible, nothing to keep open.

**Does my laptop have to stay on?** If the daemon runs on it, yes — 24/7, awake. That is the one hard requirement, and it is why the VM option exists. If it runs on a VM, your laptop can do whatever it likes.

**What happens if the machine was off at a boundary?** Nothing bad. When it comes back, the daemon probes the provider and resumes chaining from that moment. The window during the downtime was simply never primed — the first window after wake-up is anchored then, as if you had typed the first message yourself.

**Does this give me more usage?** No. Weekly caps are unchanged. It only controls *when* the 5-hour reset lands.

**Does my laptop benefit if the daemon runs on a VM?** Yes — windows belong to your account, not the machine. Every device you use with that account shares them.

**What if I work through a boundary?** Nothing special. Your messages land in whatever window is open; when it expires, the daemon (or your next message, whichever is first) starts the next one, and the daemon reads the real reset time either way.

**Can this run as a Claude Code plugin?** Not on its own: plugins only execute while Claude Code is running, so they cannot fire a trigger while you sleep. A plugin can add conveniences on top (status commands, precise timestamps from hooks), but the always-on tick stays.

## License

MIT — see `LICENSE`.
