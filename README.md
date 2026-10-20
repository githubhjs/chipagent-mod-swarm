# chipagent-mod-swarm: parallel ChipAgents teams

English | [繁體中文](README.zh-TW.md)

`chip-swarm` runs several headless ChipAgents processes (`chipagents batch`) at
the same time, each team in its own git worktree, and combines the results.
It gives ChipAgents the multi-team patterns that Claude Code users get from
agent-team and swarm plugins:

| Mode | Pattern | What you get |
|---|---|---|
| `race` | **Teams race to the goal.** N teams solve the same task with different strategies (or models / thinking levels) | The best team that passes `.chipagents/verify.sh`, or the first one with `--first`; optionally merged |
| `investigate` | **Independent investigation, then merge.** One read-only investigator per hypothesis | One report per hypothesis plus a merged `VERDICT.md` |
| `fanout` | **Many tasks in parallel** (batch map) | One verified branch per task and a summary table |

It is a single bash script: bash 4.4, git and coreutils, no jq. It is written
for CentOS 8 and also runs in Git Bash.

## Why a separate runner

- Claude Code's agent-team plugins rely on Claude-only tools (`TeamCreate`,
  `SendMessage`, a shared task list) that ChipAgents does not have.
- ChipAgents subagents run inside one session. `chip-swarm` adds
  **process-level** parallelism with separate contexts and separate
  worktrees, so teams cannot overwrite each other's files.
- Results are judged **objectively** by your verify script, not by a team's
  own claim that it is done.

## Install

```bash
git clone https://github.com/githubhjs/chipagent-mod-swarm.git
sudo install -m 0755 chipagent-mod-swarm/bin/chip-swarm /usr/local/bin/
cd <your-repo>
cp /path/to/chipagent-mod-swarm/chip-swarm.conf.example .chip-swarm.conf   # adjust --allow-edits
bash /path/to/chipagent-mod-swarm/tests/selftest.sh                          # 22 checks with a mock agent
```

- Copied the files without git (for example through a VM shared folder)? Execute
  bits are lost that way; restore them with
  `chmod +x bin/chip-swarm tests/chipagents tests/selftest.sh`. The self-test
  itself does not need them.
- The self-test works in a temporary directory under `$TMPDIR` (default `/tmp`);
  set `TMPDIR` to put it elsewhere.

Batch mode only runs shell commands listed in `.chipagents/automatic-commands.toml`
(see the template in [chipagents-loop-kit](https://github.com/githubhjs/chipagents-loop-kit/blob/main/outer-loop/automatic-commands.toml.example)),
and it can only edit files matching `--allow-edits`. Log in once with the
interactive CLI (`chipagents`, then `/login`).

## Usage

### race: teams race to the goal

```bash
chip-swarm race -n 3 task.md                 # wait for all, keep the best passing team
chip-swarm race -n 3 --first task.md         # first team that passes wins; others are stopped
chip-swarm race -n 3 --merge task.md         # also merge the winner into the current branch
chip-swarm race -n 2 --strategies strategies.txt task.md
```

- Each team gets a strategy (one per line in `--strategies`; three defaults:
  smallest change, cleanest design, test first).
- `TEAM_EXTRA_ARGS` in `.chip-swarm.conf` gives teams different options, e.g.
  `"--thinking high"` vs `"--thinking max"` or different `--provider` values.
- After each run, chip-swarm commits the team's changes on its branch
  `swarm/<run>/team-<k>` and runs `.chipagents/verify.sh` in its worktree.
- Winner: a team that passes verification; among those, the smallest diff,
  then the fewest tokens. With `--first`, the first team to pass wins and the
  other teams' process trees are stopped.
- `--merge` merges the winner with `git merge --no-ff`, through `git flock`
  when [git-flock-kit](https://github.com/githubhjs/git-flock-kit) is installed.
- Exit 0 when a team passed, 1 when none did (worktrees are kept for
  inspection).

### investigate: independent investigation, then merge

```bash
cat > hypotheses.txt <<'EOF'
H1: the RX FIFO overflows because wr_en ignores full
H2: the testbench drives data one cycle late
H3: reset is released before the clock is stable
EOF
chip-swarm investigate -j 3 hypotheses.txt bug.md
```

- One investigator per hypothesis, run in parallel. Each must gather evidence
  **for and against** its hypothesis and end with `VERDICT`, `CONFIDENCE`,
  `EVIDENCE` (file:line, log line or signal@time) and `WHAT WOULD SETTLE IT`.
- Investigators and the merge run are **read-only**: chip-swarm drops
  `--allow-edits` from their command line, so batch mode cannot edit files.
- A final merge run reads every report and writes `VERDICT.md`: which
  hypotheses survive, conflicts between reports, the most likely explanation
  with a confidence, and the next step.
- `--worktrees` gives each investigator its own worktree, for checks that
  write build or simulation output.

### fanout: many tasks in parallel

```bash
cat > tasks.md <<'EOF'
Add parity checking to uart_rx and a test for it.
---
Add a sticky overflow flag to the RX FIFO status register.
---
Update docs/uart.md for the new registers.
EOF
chip-swarm fanout -j 3 tasks.md
```

Each task runs in its own worktree and branch (`swarm/<run>/task-<k>`), is
verified and committed. Nothing is merged; review and merge the branches you
want. Exit 1 if any task failed.

### clean

```bash
chip-swarm clean                 # remove every chip-swarm worktree and branch
chip-swarm clean race-20261020   # only runs whose id starts with this
```

## Where things go

Worktrees, prompts, logs, reports and summaries go to
`../.chip-swarm/<repo name>/<run id>/` (outside the repository, set
`SWARM_DIR` to change it):

```
<run id>/
├── swarm.log
├── SUMMARY.md            race / fanout table
├── VERDICT.md            investigate result
└── team-<k>/
    ├── wt/               the team's git worktree
    ├── prompt.md         exactly what the team was asked
    ├── response.txt / report.md
    ├── agent.log, verify.log, stats.json
    └── result
```

An untracked `.chipagents/` directory (verify.sh, rules, skills, command
allowlist) is copied into every worktree so the same settings apply there.

## Workspace hooks inside team runs

Every `chipagents batch` run loads the workspace's hooks (measured on
ChipAgents 0.42.3), so gates from
[chipagents-loop-kit](https://github.com/githubhjs/chipagents-loop-kit) and
[claude-self-review-kit](https://github.com/githubhjs/claude-self-review-kit)
apply inside each team:

- **race and fanout teams** keep them: goal-gate, verify-gate and review-gate
  push each team to finish and verify its own work before chip-swarm judges it.
- **investigate and merge runs** are read-only, so chip-swarm starts them with
  `CHIPAGENTS_HOOKS_INNER=1` (and `REVIEW_GATE_INNER=1`). Those gates skip such
  runs instead of pushing an investigator that cannot edit anything.
- The rerun budget is the workspace `post_turn_restarts`; reruns = value − 1.

## Cost and safety

- N teams cost roughly N times the tokens of one run. `stats.json` records each
  team's token use and the summary shows it.
- Use `--skip-permissions` only inside an isolated sandbox or container, as the
  ChipAgents documentation says.
- Teams cannot see each other's work; contracts and shared interfaces have to be
  fixed before a fan-out, not negotiated during it.

## Test status

**On real ChipAgents 0.42.3** (measured by Josh_HUANG): a two-team race with
real `chipagents batch` runs finished in 1m47s; `.chipagents/verify.sh` picked the
winner and chip-swarm merged it (exit 0).

`tests/selftest.sh` runs 22 checks against a mock `chipagents batch` that
follows the Batch Mode documentation: best-of-N selection, per-team options,
`--first` stopping the slower teams, all teams failing, `--merge`, read-only
investigators with a merged verdict and the inner flag, fan-out with a failing
task, `clean`, and three races started at the same moment sharing one
`SWARM_DIR`. All pass in Git Bash on Windows.

That last check guards a fixed bug: run ids used to be a timestamp only, so on
a fast machine a run started in the same second as the previous one reused its
directory and died in `git worktree add`. On CentOS this made `race --merge`
and "no team passes" fail in 7 of 8 self-test runs. Run ids now carry the
process id and are claimed with an atomic `mkdir`.

## Related

- [chipagent-mod-agent-teams](https://github.com/githubhjs/chipagent-mod-agent-teams): team review, hypothesis-driven debugging and coordinated feature work as ChipAgents subagents; uses chip-swarm for process-level parallelism
- [chipagent-mod-feature-dev](https://github.com/githubhjs/chipagent-mod-feature-dev): Anthropic's feature-dev workflow (parallel explorers, architects, reviewers) for ChipAgents
- [chipagents-loop-kit](https://github.com/githubhjs/chipagents-loop-kit): keep one agent working until the goal is met
- [git-flock-kit](https://github.com/githubhjs/git-flock-kit): serialized git commits when agents share one working tree

## Projects evaluated but not ported

| Project | Why not |
|---|---|
| [ruvnet/ruflo](https://github.com/ruvnet/ruflo) (formerly claude-flow, ★77k) | Its swarm and hive-mind tools only record state (the host agent does the work); its native modules need glibc 2.29/2.34 (CentOS 8 has 2.28); it auto-installs npm updates by default; its worker mode launches the `claude` CLI |
| [Yeachan-Heo/oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode) (★40k) | Built on Claude Code's own team tools and hooks; about 100 MB of TypeScript |
| [affaan-m/claude-swarm](https://github.com/affaan-m/claude-swarm) | Requires the Claude Agent SDK |
| [am-will/swarms](https://github.com/am-will/swarms) | No license, so it cannot be redistributed |

## License

MIT. See [LICENSE](LICENSE).

## Author

Chih-Hsueh "Josh" HUANG
