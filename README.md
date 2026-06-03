> [!CAUTION]
> **DO NOT USE THIS TOOL ON CORPORATE HARDWARE OR CONNECTED TO A CORPORATE NETWORK.**
>
> This tool auto-approves all Claude Code permission prompts without human review, including destructive commands. For maximum isolation, run it on a **dedicated bare-metal server** with no personal data, no saved credentials, and no access to sensitive networks. You accept full responsibility for any consequences.

# claude-yolo

Run parallel Claude Code agents in tmux with automatic permission approval. Optionally isolate each agent in its own git worktree with real-time merge conflict detection and automated conflict resolution.

When organization-managed settings force `ask` mode for tools like `Bash`, `Bash(rm:*)`, and `WebFetch`, this tool auto-approves those prompts at the terminal level using `tmux capture-pane` + `send-keys`.

## Table of contents

- [Installation](#installation)
- [Quick start](#quick-start)
- [Worktree mode](#worktree-mode)
- [Navigation](#navigation)
- [Control commands](#control-commands)
- [Options](#options)
- [How it works](#how-it-works)
  - [Detection signals](#detection-signals)
  - [Worktree pipeline](#worktree-pipeline)
- [File structure](#file-structure)
- [Prerequisites](#prerequisites)
- [Testing](#testing)
- [Key features](#key-features)
- [Development history](#development-history)

## Installation

**One-liner** (macOS, Linux, WSL, Termux):

```bash
command -v curl >/dev/null || { s=; [ "$(id -u)" != 0 ] && s=sudo; command -v apt-get >/dev/null && { $s apt-get update && $s apt-get install -y curl; } || command -v dnf >/dev/null && $s dnf install -y curl || command -v yum >/dev/null && $s yum install -y curl || command -v apk >/dev/null && $s apk add curl || command -v pacman >/dev/null && $s pacman -S --noconfirm curl || command -v pkg >/dev/null && pkg install -y curl || command -v brew >/dev/null && brew install curl; }; curl -fsSL https://raw.githubusercontent.com/claude-yolo/claude-yolo/refs/heads/main/install.sh | bash && export PATH="$HOME/.local/bin:$PATH"
```

This clones to `~/.claude-yolo` and symlinks the binary into `~/.local/bin`. It also installs `git`, `tmux`, `curl`, and `claude` (Claude Code CLI) if they are missing. Override the install location with `CLAUDE_YOLO_HOME`, the symlink location with `CLAUDE_YOLO_BIN_DIR`, and the npm prefix used for fallback installs with `CLAUDE_YOLO_NPM_PREFIX`. On locked-down hosts without usable `sudo`, the installer falls back to user-space installs and a writable bin directory automatically:

```bash
command -v curl >/dev/null || { s=; [ "$(id -u)" != 0 ] && s=sudo; command -v apt-get >/dev/null && { $s apt-get update && $s apt-get install -y curl; } || command -v dnf >/dev/null && $s dnf install -y curl || command -v yum >/dev/null && $s yum install -y curl || command -v apk >/dev/null && $s apk add curl || command -v pacman >/dev/null && $s pacman -S --noconfirm curl || command -v pkg >/dev/null && pkg install -y curl || command -v brew >/dev/null && brew install curl; }; CLAUDE_YOLO_HOME=~/my/path curl -fsSL https://raw.githubusercontent.com/claude-yolo/claude-yolo/refs/heads/main/install.sh | bash && export PATH="$HOME/.local/bin:$PATH"
```

**Local install** (from a cloned repo, no network access needed):

```bash
git clone https://github.com/claude-yolo/claude-yolo.git ~/.claude-yolo
cd ~/.claude-yolo
./install.sh --local
```

**Manual install:**

```bash
git clone https://github.com/claude-yolo/claude-yolo.git ~/.claude-yolo
ln -s ~/.claude-yolo/claude-yolo ~/.local/bin/claude-yolo
```

Then run from any project directory:

```bash
cd /path/to/your/project
claude-yolo "fix the tests" "update docs"
```

The tool runs agents in whatever directory you invoke it from (or the `-d`/`--dir` path if specified).

## Quick start

```bash
# Run three agents in parallel
claude-yolo "fix the login bug" "add unit tests for auth" "update the README"

# Use a specific model
claude-yolo -m opus "refactor the API layer"

# Point agents at a different project
claude-yolo -d /path/to/project "run the test suite and fix failures"
```

Once launched, you're inside a tmux session with one window per agent. The last window (`control`) tails the audit log in real time and accepts slash commands.

## Worktree mode

With `--worktree` (`-w`), each agent gets its own git worktree and branch — full isolation, no stepping on each other's files:

```bash
claude-yolo -w -s feat -d /path/to/repo \
  "implement auth system" \
  "add database migrations" \
  "write API tests"
```

This creates three worktrees (`feat-1`, `feat-2`, `feat-3`), each branched from the current HEAD. While agents work:

- A **conflict daemon** polls `git merge-tree` every 5 seconds across all branch pairs and logs detected conflicts to the audit log
- The **merge resolver** waits for all agents to finish, auto-commits any uncommitted changes, then sequentially merges each branch into the base
- On merge conflict, a **resolver agent** (another Claude instance) is spawned to read the conflict markers, resolve them, and commit the merge

```
tmux windows in worktree mode:

  agent-1   agent-2   agent-3   merge   control
  ────────  ────────  ────────  ──────  ────────
  Claude in Claude in Claude in Waits,  Tails
  worktree  worktree  worktree  then    audit
  feat-1/   feat-2/   feat-3/   merges  log
```

Skip auto-merge to inspect worktrees manually:

```bash
claude-yolo -w --no-merge -s feat -d /repo "task1" "task2"

# After agents finish, inspect and merge yourself:
git diff main..feat-1
git diff main..feat-2
git checkout main && git merge feat-1 && git merge feat-2

# Clean up worktrees:
source ~/.claude-yolo/lib/worktree-manager.sh && wt_cleanup feat
```

See [docs/worktree-mode-demo.md](docs/worktree-mode-demo.md) for a full walkthrough with a demo repo.

## Navigation

| Key | Action |
|---|---|
| `Ctrl-b w` | List all agent windows and select one |
| `Ctrl-b s` | Switch between agent windows |
| `Ctrl-b n` | Next pane |
| `Ctrl-b p` | Previous pane |
| `Ctrl-b x` | Stop the current agent, close pane |
| `Ctrl-b d` | Detach (agents keep running) |

Re-attach later with `claude-yolo -r` (or `claude-yolo --resume`).

## Control commands

The `control` window accepts slash commands while continuing to show the audit log. Up-arrow recalls earlier commands.

```bash
/loop 1h Continue experiments and push best submission
/queue ["read README.md", "summarize it", "/clear"]
/plan refactor the parser
/loop 30m /queue ["check status", "summarize"]
/loop 1h /plan run the daily checks
```

Available commands:

| Command | Action |
|---|---|
| `/plan [prompt]` | Send `/plan <prompt>` to `agent-1` and auto-approve the resulting ExitPlanMode prompt for that send |
| `/queue ["item1", "item2"]` | Run queued prompts/slash commands sequentially in `agent-1` |
| `/queue add <id> ["item"]` | Append pending items to an existing queue |
| `/queue edit <id> <n> ["item"]` | Replace one pending queue item |
| `/queue remove <id> <n\|a-b>` | Remove pending queue item(s) |
| `/queue dequeue <id>` | Remove the next pending item from a queue |
| `/queue show <id>` | Show items in a queue and their status |
| `/queues` | List active queues |
| `/queues cancel <id>` | Cancel a queue |
| `/loop <interval> <prompt>` | Send `<prompt>` to `agent-1` immediately, then every interval until canceled |
| `/loop <interval> /queue [...]` | Re-run a queue every interval |
| `/loop <interval> /plan <prompt>` | Run `/plan <prompt>` every interval, with auto-approval each cycle |
| `/loops` | List active loops |
| `/loops cancel <id>` | Cancel one loop |
| `/help` | Show command help |

Intervals are whole numbers with `s`, `m`, `h`, or `d`, for example `30s`, `15m`, `1h`, or `1d`.
`/loop`, `/queue`, and `/plan` are disabled in worktree mode because agent windows may exit after completing their assigned task.

### One-shot control commands from the CLI

Pass `-c "/..."` to run a single slash command in the `control` window right after launch — same effect as typing it at the `claude-yolo>` prompt. To compose multiple commands, wrap them in `/queue [...]` rather than repeating `-c`.

```bash
claude-yolo -c "/loop 10m /plan Draft the next implementation plan"
claude-yolo -c '/queue ["/plan first", "/loop 1h /plan continue"]'
claude-yolo --resume -c "/loops"
```

Multi-line strings are sent as a paste, so multi-line `/plan` and `/queue` work:

```bash
claude-yolo -c "$(printf '/plan line one\nline two\nline three')"
```

### Plan-mode auto-approval is scoped

`/plan` from the control pane drops a marker file (`<audit-log>.plan-approval`) tagged with the agent pane id and a timestamp. The approver daemon only auto-confirms an ExitPlanMode prompt when the marker matches the pane and is within `CLAUDE_YOLO_PLAN_APPROVAL_TTL` seconds (default 3600). User-initiated plan mode in the agent window does **not** get auto-approved — the prompt waits for the user.

Slash commands queued via `/queue` use a similar scoped marker (`<audit-log>.slash-approval`, default TTL 60 s, override with `CLAUDE_YOLO_SLASH_APPROVAL_TTL`).

### Tunable env vars

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDE_YOLO_CONTROL_SUBMIT_DELAY` | `0.2` | Pause after pasting a one-line prompt before sending Enter |
| `CLAUDE_YOLO_CONTROL_MULTILINE_PASTE_DELAY` | `0.8` | Pause after a multi-line paste before sending Enter |
| `CLAUDE_YOLO_CONTROL_PLAN_PASTE` | `auto` | `1`/`0` to force-enable/disable continuation-line capture for `/plan` and `/loop` payloads pasted from the terminal |
| `CLAUDE_YOLO_CONTROL_PLAN_PASTE_GRACE` | `0.5` | Grace window for collecting pasted continuation lines |
| `CLAUDE_YOLO_CONTROL_QUEUE_WAIT_DELAY` | `1` | Poll interval while waiting for `agent-1` to return to idle between queue items |
| `CLAUDE_YOLO_CONTROL_QUEUE_POST_SEND_GRACE` | `0.5` | Pause after sending a queue item before the idle wait begins |
| `CLAUDE_YOLO_CONTROL_QUEUE_LOCK_DELAY` | `0.05` | Backoff while contending for the queue state lock |
| `CLAUDE_YOLO_PLAN_APPROVAL_TTL` | `3600` | TTL (seconds) for the plan-approval marker |
| `CLAUDE_YOLO_SLASH_APPROVAL_TTL` | `60` | TTL (seconds) for the slash-approval marker |
| `CLAUDE_YOLO_CONTROL_INJECT_ATTEMPTS` | `100` | Max polls waiting for the control pane to be ready when injecting a `-c/--command` |
| `CLAUDE_YOLO_CONTROL_INJECT_DELAY` | `0.1` | Pause between those polls |

## Options

```
-s, --session NAME    Custom tmux session name (default: claude-yolo-<timestamp>)
-d, --dir PATH        Working directory for agents (default: current directory)
-m, --model MODEL     Claude model to use (e.g., opus, sonnet, haiku)
-p, --poll SECONDS    Approver poll interval (default: 0.3)
-f, --file FILE       Read a multiline prompt from a text file
-c, --command STRING  Slash command to run in the control pane after launch
                      (e.g. "/loop 10m /plan ...", "/queue [...]", "/help").
                      Must start with '/'. Multi-line strings are sent as a paste.
                      Works with --resume to inject into an existing session.
-r, --resume          Re-attach to an existing yolo session
-h, --help            Show help

Worktree options:
-w, --worktree          Run each agent in its own git worktree
--base-branch BRANCH    Base branch for worktrees (default: current branch)
--no-merge              Skip auto-merge after agents complete
--no-cleanup            Keep worktrees after merge
--conflict-poll SECS    Conflict detection interval (default: 5)

install.sh options:
--local               Install from the local repo without pulling from GitHub
```

## How it works

1. **Launcher** (`claude-yolo`) creates a tmux session and spawns one window per task, each running `claude`. At startup it also auto-trusts the working directory (so Claude Code skips the "trust this folder" prompt) and, **if you have not already set a notification preference**, configures `~/.claude/settings.json` to ring the terminal bell when a task finishes or your input is requested (`preferredNotifChannel: terminal_bell` plus a `Stop` hook). An existing channel choice or `Stop` hook is left untouched.
2. **Control pane** (`lib/control-pane.sh`) opens the `control` window, tails the audit log, and handles slash commands such as `/loop`.
3. **Approver daemon** (`lib/approver-daemon.sh`) runs in the background, polling every 0.3s. For each pane it:
   - Captures visible content via `tmux capture-pane`
   - Detects three prompt styles (see below)
   - Sends `Enter` via `tmux send-keys` to confirm the pre-selected option
   - If the transcript is collapsed (`● Bash(...)` visible but prompt hidden), sends `Ctrl+O` to expand it first — the next poll cycle then approves
   - Applies a 2-second per-pane cooldown to prevent double-approvals
4. **Audit log** at `/tmp/claude-yolo-<session>.log` records every approval and control event with timestamps. Each session gets its own log, so concurrent claude-yolo processes don't interfere.

### Worktree pipeline

When `--worktree` is enabled, three additional components run alongside the approver:

1. **Worktree manager** (`lib/worktree-manager.sh`) creates a git worktree per agent in `<repo>-worktrees/<session>/`, each on its own branch forked from the base. A state file tracks branches and paths for later cleanup.
2. **Conflict daemon** (`lib/conflict-daemon.sh`) polls every `--conflict-poll` seconds (default 5). For each unique pair of worktree branches it runs `git merge-tree --write-tree` (a read-only plumbing command, git 2.38+) to simulate a merge. Conflicts are logged to the audit log — visible in the `control` window.
3. **Merge resolver** (`lib/merge-resolver.sh`) runs in a `merge` tmux window. It detects when each agent returns to the idle prompt (`❯`) and sends `/exit` to close Claude, then auto-commits any uncommitted changes. Branches are merged sequentially into the base. On conflict, a new Claude instance is spawned in a `resolve` window to read the conflict markers, resolve them, and commit the merge. The approver daemon handles the resolver's permission prompts.

### Detection signals

The approver requires the primary signal plus at least one secondary signal to fire:

**Expanded view** — requires primary + secondary signal:

| Signal | Type | Patterns |
|---|---|---|
| Allow + Deny | Primary (either) | Both `Allow` and `Deny` in last 20 lines |
| N. Yes / N. No | Primary (either) | Numbered options like `1. Yes` and `2. No` |
| Tool keywords | Secondary (at least one) | `Bash`, `WebFetch`, `Read`, `Write`, `Edit`, `execute`, `run` |
| Context phrases | Secondary (at least one) | `want to proceed`, `wants to execute`, `wants to run`, `permission`, `allow once`, `allow always` |

**Collapsed view** — detected when the transcript is toggled off:

| Signal | Patterns |
|---|---|
| Pending tool indicator | `● Bash(...)`, `● WebFetch(...)`, `● Read(...)`, etc. |
| Collapsed view marker | `Showing detailed transcript` in the last 10 lines |

When a collapsed view is detected, the daemon sends `Ctrl+O` to expand it, then detects and approves the prompt on the next poll cycle.

## File structure

```
claude-yolo              # Main launcher script
lib/
  common.sh              # Logging, prerequisite checks, git helpers
  control-pane.sh        # Interactive control window + slash command scheduler
  approver-daemon.sh     # tmux capture-pane monitor + auto-approver
  worktree-manager.sh    # Git worktree lifecycle (create, list, cleanup)
  conflict-daemon.sh     # Real-time conflict detection via git merge-tree
  merge-resolver.sh      # Sequential merge + Claude-powered conflict resolution
test_approver.sh         # Test suite (226 tests)
docs/
  worktree-mode-demo.md  # Step-by-step demo with Ubuntu 24.04 container
```

## Prerequisites

- **tmux** (tested with 3.4)
- **claude** (Claude Code CLI)
- **git** 2.38+ (required for worktree mode — `git merge-tree --write-tree`)

## Testing

```bash
# Run all tests
bash test_approver.sh

# Verbose output (shows passing tests)
bash test_approver.sh -v

# Filter by pattern
bash test_approver.sh WebFetch
bash test_approver.sh "Bash(rm"
bash test_approver.sh Integration
```

The test suite covers:
- Prompt detection for Bash, Bash(rm:\*), and WebFetch permission patterns
- False positive resistance (code output, markdown, missing signals)
- Cooldown logic, command construction, audit logging
- End-to-end integration tests using real tmux sessions
- Worktree creation, state file management, and cleanup
- Conflict detection via `git merge-tree` (conflicting and clean merges)
- Merge branch operations (fast-forward, divergent, conflict)
- Launcher worktree flag parsing and validation

## Key features

- **Parallel multi-agent execution** — Run multiple Claude Code agents in tmux with non-invasive, terminal-level auto-approval of permissions.
- **Git worktree isolation** — Each agent works in its own worktree and branch. No file conflicts during execution, clean merge afterward.
- **Real-time conflict detection** — A background daemon polls `git merge-tree` across all branch pairs and logs conflicts as they emerge.
- **Automated conflict resolution** — On merge conflict, a Claude agent is spawned to read both sides, resolve conflict markers, and commit the merge.
- **Sophisticated detection logic** — Handles both expanded and collapsed transcript views without modifying the Claude CLI or relying on the `--dangerously-skip-permissions` flag.
- **Reliability and traceability** — Per-pane cooldowns, detailed audit logging, and 226 tests emphasize reliability and traceability.
- **No CLI patching or containerization** — Avoids direct CLI patching or containerization, suitable for environments where `ask` mode is enforced.

## Development history

This tool was built iteratively through real-world testing against Claude Code v2.1.42. Key discoveries along the way:

1. **Prompt format**: Claude Code renders permission prompts as `❯ 1. Yes / 2. No` with `Do you want to proceed?` and `Permission rule Bash requires confirmation`. An older `Allow / Deny` button style also exists — both are supported.

2. **Approval keystroke**: Sending `y` via `tmux send-keys` does nothing. Only `Enter` works because the prompt has a pre-selected option (`❯ 1. Yes`).

3. **Collapsed transcript view**: When Claude Code's transcript is toggled off, `tmux capture-pane` shows `● Bash(ls ...)` and `Showing detailed transcript` but no permission prompt text. The daemon detects this state and sends `Ctrl+O` to expand the transcript, then approves on the next poll cycle.

4. **Multi-signal detection**: Simple keyword matching produces too many false positives (code output, markdown, log messages). The two-tier approach (primary signal + secondary signal) eliminates these.

5. **Per-pane cooldown**: Without a cooldown, the 0.3s poll interval can send multiple `Enter` keystrokes for the same prompt. A 2-second per-pane cooldown prevents double-approvals.
