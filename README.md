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

## Which one to use

Pick the mode first: picking the wrong one wastes the most time.

| You want | Use | How |
|---|---|---|
| several strategies competing, the winner kept | `chip-swarm race` | separate processes, a script decides |
| several hypotheses checked independently, then merged | `chip-swarm investigate` | read-only investigators plus one merge run |
| several independent tasks in parallel | `chip-swarm fanout` | one worktree each |
| a team inside the current session | [agent-teams](https://github.com/githubhjs/chipagent-mod-agent-teams) | subagents, no new processes |
| explore, design and review one feature | [feature-dev](https://github.com/githubhjs/chipagent-mod-feature-dev) | parallel exploration, then design |

The key difference: [chip-swarm](https://github.com/githubhjs/chipagent-mod-swarm)
starts **real separate processes**, every team has its own context, and a
script decides the result. agent-teams and feature-dev run inside the current
session and share its context.

chip-swarm is a CLI, not a plugin: it has no marketplace.json or plugin.json.
Put `bin/chip-swarm` on `PATH`. agent-teams and feature-dev are Claude-format
plugins, installed with `--type claude`.

### Before the first run: two files

- `.chip-swarm.conf` at the repository root (bash syntax). Start `AGENT_ARGV`
  with the **absolute path** of the ChipAgents binary your sessions use
  (0.42.3 where this was measured), not whichever `chipagents` comes first on
  `PATH`: there it was 0.20.2, which also installs plugins without their hook
  metadata.
- `.chipagents/verify.sh` decides pass or fail. It may be untracked:
  chip-swarm copies the untracked `.chipagents/` into every worktree. **Never
  put it in `~/.chipagents/`**: there it would gate every session you run.

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

## Field report: ChipAgents 0.42.3 (2026-10-20)

Measured by Josh_HUANG on a CentOS 8 machine with real `chipagents batch`
runs. Every number below comes from a command that was actually run.

| Mode | Result | Time |
|---|---|---|
| `race -n 2 --merge` | rc=0, team-2 won and was merged | 1m47s |
| `investigate -j 2` | rc=0, a 38-line VERDICT | 2m23s |
| `fanout -j 2` | rc=0, 2/2 tasks, two branches | 47.7s |

```bash
chip-swarm race        -n 2 --merge task.md
chip-swarm investigate -j 2 hyp.txt bug.md
chip-swarm fanout      -j 2 tasks.txt
chip-swarm clean       [RUN_ID]
```

The race log:

```
11:01:35  team 1 started: Make the smallest change that satisfies...
11:01:35  team 2 started: Prefer the cleanest, most maintainable...
11:03:22  winner: swarm/race-20261020-110135/team-2
11:03:23  merged ... into master
```

By default the best passing team wins (smallest diff, then fewest tokens).
`--first` takes the first team that passes and stops the others. `--merge`
merges the winner; without it chip-swarm prints the `git merge` command and
leaves the decision to you.

### investigate is the most underrated mode

One **read-only** investigator per hypothesis (it never gets `--allow-edits`,
so it cannot change anything), then one merge run. The test was a deliberately
broken 4-line `fifo.v` with two hypotheses:

```
H1: cnt has no reset, so it starts X
H2: cnt wraps silently at 15
```

The merge run did the most important thing: it **re-read fifo.v itself**
instead of taking the reports at their word (translated from the original
Chinese verdict):

```
Own check: read all of fifo.v (4 lines); both reports quote it exactly.
H1  no reset, X at power-up    -> SUPPORTED
H2  silent wrap at 15          -> the behaviour is real; as the root cause, REFUTED
Conflicts between reports: none of substance. Most likely explanation, confidence 95.
```

Note how H2 was judged: the behaviour exists, but it was **refuted as the
root cause**. A single agent easily conflates the two; telling them apart is
what independent investigation followed by a merge is for.

For hypotheses that need a build or a simulation, add `--worktrees` so each
investigator gets its own working directory.

### Known issues

1. **Execute bits get lost in transit.** After a copy through a VM shared
   folder, three files had no `x` bit and the self-test died before it
   started: `chmod +x bin/chip-swarm tests/chipagents tests/selftest.sh`.
   Fixing the modes in this repository (they are recorded as 100755) cannot
   help that path. The self-test now copies the mock and sets its bit itself.
2. **The self-test was flaky. Fixed.** In 8 runs on that machine, "race
   --merge: winner merged" failed 7 times and "race: exits 1 when no team
   passes" 3 times, while the same race --merge scenario in a clean, isolated
   fixture passed 4 of 4 and real races succeeded, which pointed at the
   self-test's fixture. Root cause, found afterwards and fixed in `ac64f10`:
   run ids were a timestamp only, the self-test cases shared one `SWARM_DIR`,
   and a race started in the same second as the previous one reused its
   directory and died in `git worktree add` (exit 64). The hypothesis that
   several `new_repo` cases sharing `$work` made their `.chip-swarm`
   directories interfere was refuted on the machine because the self-test's
   `SWARM_DIR` was `$work/swarm`, not `.chip-swarm`. Run ids now include the
   process id and are claimed with an atomic `mkdir`, every case has its own
   `SWARM_DIR`, and a regression check starts three races at the same moment
   (the old code fails it). The fix was reproduced and verified in Git Bash;
   it has not been re-run on CentOS yet.
3. The self-test uses `mktemp -d`, which lands in `/tmp`. Where `/tmp` is not
   allowed, set `TMPDIR`.

### Not verified

- Whether ChipAgents runs several subagents at the same time. Measured: a
  subagent's turn **does** trigger `post_turn` hooks but does **not** appear
  in the run log, so it can only be seen through side effects. Concurrency
  itself was not measured. This matters for agent-teams and feature-dev, not
  for chip-swarm, whose teams are separate processes.
- agent-teams and feature-dev: see the field reports in their READMEs.

## Test status

**On real ChipAgents 0.42.3**: see the
[field report](#field-report-chipagents-0423-2026-10-20) above.

`tests/selftest.sh` runs 22 checks against a mock `chipagents batch` that
follows the Batch Mode documentation: best-of-N selection, per-team options,
`--first` stopping the slower teams, all teams failing, `--merge`, read-only
investigators with a merged verdict and the inner flag, fan-out with a failing
task, `clean`, and three races started at the same moment sharing one
`SWARM_DIR`. All pass in Git Bash on Windows.

That last check guards a fixed bug: run ids used to be a timestamp only, so on
a fast machine a run started in the same second as the previous one reused its
directory and died in `git worktree add`. On CentOS this made `race --merge`
fail in 7 of 8 self-test runs and "no team passes" in 3 of 8 (see Known
issues above). Run ids now carry the process id and are claimed with an
atomic `mkdir`.

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
