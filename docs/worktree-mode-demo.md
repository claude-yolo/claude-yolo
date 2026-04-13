# Worktree Mode Demo

Step-by-step guide to showcase worktree isolation, merge conflict detection, auto-merge, and conflict resolution in a fresh Ubuntu 24.04 container.

## 1. Configure git

```bash
git config --global user.name "Demo"
git config --global user.email "demo@test.com"
```

## 2. Install claude-yolo

The installer handles all dependencies (git, tmux, Claude Code CLI):

```bash
git clone https://github.com/claude-yolo/claude-yolo.git /tmp/claude-yolo-src
bash /tmp/claude-yolo-src/install.sh --local
source ~/.bashrc
```

This installs git and tmux via apt (skips `sudo` when running as root), installs the Claude Code CLI, copies claude-yolo to `~/.claude-yolo`, and symlinks the binary into `~/.local/bin`.

## 3. Create a demo repo

The key to seeing conflicts: multiple agents must edit **the same lines** in the same file. This repo has a small `app.py` where every task forces changes to the function bodies and the `main` block.

```bash
mkdir -p /tmp/demo-project && cd /tmp/demo-project
git init -b main
cat > app.py << 'EOF'
def hello():
    return "Hello, World!"

def add(a, b):
    return a + b

def multiply(a, b):
    return a * b

if __name__ == "__main__":
    print(hello())
    print(add(2, 3))
    print(multiply(4, 5))
EOF
git add -A && git commit -m "initial commit"
```

## 4. Launch worktree mode (guaranteed conflicts)

All three agents rewrite overlapping parts of `app.py` -- the function bodies and the `main` block. This guarantees merge conflicts.

```bash
claude-yolo --worktree -s demo -d /tmp/demo-project \
  "Rewrite app.py: rename hello to greet, add to sum_numbers, multiply to product. Add docstrings to every function. Update the main block to use the new names and print descriptive labels like 'Greeting: ...', 'Sum: ...', 'Product: ...'. Commit your changes with git add -A && git commit -m 'rename and document functions'" \
  "Rewrite app.py: add type hints (int/float) to all function signatures, add input validation that raises TypeError for non-numeric args in add and multiply, add a subtract(a,b) function, and update the main block to also call subtract. Commit your changes with git add -A && git commit -m 'add types and validation'" \
  "Rewrite app.py: add a divide(a,b) function with ZeroDivisionError handling, add a power(a,b) function, and rewrite the main block to demo all functions including divide and power. Commit your changes with git add -A && git commit -m 'add divide and power'"
```

The explicit "Commit your changes" instruction ensures each agent commits to its branch, which is needed for both conflict detection and merging.

## What you'll see in tmux

| Window | What's happening |
|--------|-----------------|
| `agent-1` | Renaming functions + adding docstrings in worktree `demo-1` |
| `agent-2` | Adding type hints + validation in worktree `demo-2` |
| `agent-3` | Adding divide/power functions in worktree `demo-3` |
| `merge` | Waiting for agents, then auto-merging + resolving conflicts |
| `control` | Live audit log with conflict detection |

## Navigate inside the session

```
Ctrl-b n          next window
Ctrl-b p          previous window
Ctrl-b 0-4        jump to window by number
Ctrl-b d          detach (session keeps running)
claude-yolo -r    re-attach later
```

## Watch conflicts in real-time

Switch to the `control` window (`Ctrl-b` then `4`). Once agents commit, you'll see:

```
[12:34:56] CONFLICT demo-1 <> demo-2: CONFLICT (content): Merge conflict in app.py
[12:34:56] CONFLICT demo-1 <> demo-3: CONFLICT (content): Merge conflict in app.py
[12:34:56] CONFLICT demo-2 <> demo-3: CONFLICT (content): Merge conflict in app.py
[12:34:56] CONFLICT scan: 3/3 pairs have conflicts
```

Note: the conflict daemon compares committed branch states. If agents haven't committed yet, no conflicts appear. The demo tasks include explicit commit instructions so conflicts are detected while agents work.

## After agents finish

The `merge` window automatically:

1. Auto-commits any remaining uncommitted changes in each worktree
2. Merges `demo-1` into `main` (always clean -- first merge)
3. Merges `demo-2` into `main` -- conflicts with demo-1's changes to `app.py`
4. On conflict -- spawns a Claude resolver agent to fix conflict markers
5. Merges `demo-3` into `main` -- conflicts again, resolved automatically
6. Cleans up worktrees and branches

## Verify the result

```bash
cd /tmp/demo-project
git log --oneline          # see all merged commits
cat app.py                 # combined result from all three agents
```

## Manual merge workflow

Use `--no-merge` to skip auto-merge and inspect worktrees before merging yourself:

```bash
claude-yolo -w --no-merge -s manual -d /tmp/demo-project \
  "task one" "task two" "task three"
```

After agents finish, inspect their work:

```bash
# See what each agent changed
cd /tmp/demo-project
git log --oneline main..manual-1    # commits from agent 1
git diff main..manual-1             # full diff from agent 1
git diff main..manual-2             # full diff from agent 2

# Preview conflicts before merging
git merge-tree --write-tree manual-1 manual-2

# Merge manually, one branch at a time
git checkout main
git merge manual-1                  # first merge is always clean
git merge manual-2                  # may conflict -- resolve manually
git merge manual-3                  # resolve if needed

# If a merge conflicts, resolve and commit
# (edit files to fix conflict markers, then:)
git add -A && git commit --no-edit

# Clean up when done
source ~/.claude-yolo/lib/worktree-manager.sh
wt_cleanup manual
```

You can also use `--no-cleanup` with auto-merge to keep worktrees around for post-merge inspection:

```bash
claude-yolo -w --no-cleanup -s keep -d /tmp/demo-project \
  "task one" "task two"

# After merge completes, worktrees are still available:
ls /tmp/demo-project-worktrees/keep/
# Clean up manually when done:
source ~/.claude-yolo/lib/worktree-manager.sh
wt_cleanup keep
```

## Other options

```bash
# Faster conflict polling (every 2 seconds instead of default 5)
claude-yolo -w --conflict-poll 2 -s fast -d /tmp/demo-project \
  "task one" "task two"

# Use a specific model
claude-yolo -w --model opus -s feat -d /tmp/demo-project \
  "task one" "task two"

# Use a different base branch
claude-yolo -w --base-branch develop -s feat -d /tmp/demo-project \
  "task one" "task two"
```
