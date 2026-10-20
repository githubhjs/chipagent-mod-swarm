#!/bin/bash

# selftest.sh: exercise every chip-swarm mode against a mock `chipagents
# batch` (tests/chipagents) in throw-away git repositories.
#
#   bash tests/selftest.sh
#
# Exit status is 0 when every check passes. Nothing outside a temporary
# directory is touched; it is created under $TMPDIR (default /tmp), so set
# TMPDIR to work elsewhere. Set KEEP=1 to keep it for inspection.
#
# Execute bits are not required: files copied through a VM shared folder lose
# them, so chip-swarm is run with bash and the mock agent is copied into the
# temporary directory and made executable there.

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
swarm="$(cd "$here/.." && pwd)/bin/chip-swarm"
work="$(mktemp -d)"
mkdir -p "$work/bin"
cp "$here/chipagents" "$work/bin/chipagents"
chmod +x "$work/bin/chipagents"
export PATH="$work/bin:$PATH" MOCK_LOG="$work/mock.log"
passed=0
failed=0

check() {
  local label="$1"
  shift
  if "$@"; then
    echo "PASS  $label"
    passed=$((passed + 1))
  else
    echo "FAIL  $label"
    # Show why: the end of chip-swarm's stderr for the case that just ran.
    tail -n 5 "$work/err.txt" 2> /dev/null | sed 's/^/      | /'
    failed=$((failed + 1))
  fi
}

new_repo() {
  local dir="$work/$1"
  mkdir -p "$dir/.chipagents"
  # Each case gets its own SWARM_DIR, so one case's runs cannot affect another.
  export SWARM_DIR="$work/$1.swarm"
  cd "$dir" || exit 1
  git init -q
  git config user.name selftest
  git config user.email selftest@example.invalid
  echo "# repo" > README.md
  git add README.md
  git commit -qm init
  # Untracked on purpose: chip-swarm must copy it into every worktree.
  printf '#!/bin/bash\ngrep -qx ok answer.txt\n' > .chipagents/verify.sh
  printf '%s\n' 'AGENT_ARGV=(chipagents batch --name "{name}" --prompt-file "{prompt_file}" --output "{output_file}" --stats-file "{stats_file}" --allow-edits "rtl/**" "answer.txt" "extra.txt")' \
    'TEAM_EXTRA_ARGS=("" "--thinking high" "")' > .chip-swarm.conf
  echo "Make answer.txt say ok." > task.md
  : > "$MOCK_LOG"
}

summary_has() { grep -q -- "$1" "$work/out.txt"; }

echo "chip-swarm self-test in $work"

new_repo race
MOCK_PLAN="1:fail:0,2:passbig:0,3:pass:1" bash "$swarm" race -n 3 task.md > "$work/out.txt" 2> "$work/err.txt"
check "race: exits 0 when a team passes" test $? -eq 0
check "race: smallest passing diff wins (team 3)" summary_has '| 3 (winner)'
check "race: failing team reported" summary_has '| 1 | .* | 0 | fail'
check "race: per-team extra args reach team 2" grep -q 'extra=--thinking=high' "$MOCK_LOG"
check "race: team runs keep the workspace gates (no inner flag)" bash -c "! grep -q 'inner=1' '$MOCK_LOG'"

new_repo first
start=$SECONDS
MOCK_PLAN="1:pass:6,2:pass:0,3:fail:30" bash "$swarm" race -n 3 --first task.md > "$work/out.txt" 2> "$work/err.txt"
elapsed=$((SECONDS - start))
check "race --first: team 2 wins" summary_has '| 2 (winner)'
check "race --first: slower teams are stopped" summary_has '| 3 | .* | stopped'
check "race --first: does not wait for the 30 s team (${elapsed}s)" test "$elapsed" -lt 30

new_repo allfail
MOCK_PLAN="1:fail:0,2:crash:0" bash "$swarm" race -n 2 task.md > "$work/out.txt" 2> "$work/err.txt"
check "race: exits 1 when no team passes" test $? -eq 1

new_repo merge
MOCK_PLAN="1:pass:0,2:fail:0" bash "$swarm" race -n 2 --merge task.md > "$work/out.txt" 2> "$work/err.txt"
check "race --merge: winner merged into the current branch" grep -qx ok answer.txt

new_repo investigate
printf '# hypotheses\nH1: FIFO overflow\nH2: testbench drives data late\n\nH3: reset released too early\n' > hyp.txt
echo "uart_tb fails at 1200ns" > bug.md
bash "$swarm" investigate -j 3 hyp.txt bug.md > "$work/out.txt" 2> "$work/err.txt"
check "investigate: exits 0 with a verdict" test $? -eq 0
check "investigate: merge run saw all 3 reports" summary_has 'from 3 reports'
check "investigate: no run got --allow-edits" bash -c "! grep -q 'edits=[1-9]' '$MOCK_LOG'"
check "investigate: 3 investigators + 1 merge run" test "$(wc -l < "$MOCK_LOG")" -eq 4
check "investigate: every run marked inner (gates skip read-only runs)" test "$(grep -c 'inner=1' "$MOCK_LOG")" -eq 4

new_repo fanout
printf 'Task A: make answer.txt say ok\n---\nTask B: crash\n---\n\nTask C: make answer.txt say ok\n' > tasks.md
MOCK_PLAN="1:pass:0,2:crash:0,3:pass:0" bash "$swarm" fanout -j 2 tasks.md > "$work/out.txt" 2> "$work/err.txt"
check "fanout: exits 1 when a task fails" test $? -eq 1
check "fanout: 3 task branches created" test "$(git branch --list 'swarm/*' | wc -l)" -eq 3

bash "$swarm" clean > /dev/null
check "clean: branches removed" test "$(git branch --list 'swarm/*' | wc -l)" -eq 0
check "clean: worktrees removed" test "$(git worktree list | wc -l)" -eq 1

# Regression: runs that start in the same second must not collide. Run ids
# used to be a timestamp only, so on a fast machine the second run reused the
# first one's directory and died in `git worktree add`.
shared="$work/shared.swarm"
for name in twin-a twin-b twin-c; do
  new_repo "$name"
done
for name in twin-a twin-b twin-c; do
  (
    cd "$work/$name" || exit 1
    SWARM_DIR="$shared" MOCK_PLAN="1:pass:0" bash "$swarm" race -n 1 --merge task.md > out.txt 2> err.txt
    echo $? > rc
  ) &
done
wait
cat "$work"/twin-*/err.txt > "$work/err.txt" 2> /dev/null
check "concurrent runs sharing a SWARM_DIR: all exit 0" test "$(cat "$work"/twin-*/rc | tr -d '\n')" = 000
check "concurrent runs: each got its own run directory" test "$(ls "$shared" | wc -l)" -eq 3
check "concurrent runs: every repo has the merged result" \
  bash -c "for d in '$work'/twin-*; do grep -qx ok \"\$d/answer.txt\" || exit 1; done"

echo
echo "$passed passed, $failed failed"
if [[ -n "${KEEP:-}" ]]; then
  echo "kept: $work"
else
  rm -rf "$work"
fi
[[ $failed -eq 0 ]]
