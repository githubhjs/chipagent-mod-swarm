# chipagent-mod-swarm：多個 ChipAgents team 平行跑

[English](README.md) | 繁體中文

`chip-swarm` 會同時跑好幾個非互動的 ChipAgents（`chipagents batch`），每個 team 有自己的 git worktree，最後把結果整合起來。Claude Code 使用者用 agent team、swarm 類 plugin 做到的多 team 模式，用它就能在 ChipAgents 上做到：

| 模式 | 用途 | 得到什麼 |
|---|---|---|
| `race` | **多 team 分路競速**：N 個 team 用不同策略（或不同模型、thinking 等級）解同一個任務 | 通過 `.chipagents/verify.sh` 的最佳 team；加 `--first` 則取最先通過的；可自動 merge |
| `investigate` | **多 team 獨立調查再合流**：每個假設一個唯讀調查員 | 每個假設一份報告，加上合併後的 `VERDICT.md` |
| `fanout` | **多個任務平行跑**（batch map） | 每個任務一個驗證過的 branch，加一張總表 |

整個工具就是一支 bash script，只需要 bash 4.4、git 和 coreutils，不需要 jq。它是為 CentOS 8 寫的，在 Git Bash 也能跑。

## 該用哪一個

先選對模式，這一步選錯最浪費時間。

| 你要的 | 用哪個 | 怎麼做到 |
|---|---|---|
| 多種策略競賽，勝者出線 | `chip-swarm race` | 獨立行程，腳本裁決 |
| 多個假設獨立查證再合流 | `chip-swarm investigate` | 唯讀調查者＋合流 |
| 多個獨立任務並行 | `chip-swarm fanout` | 各自 worktree |
| 團隊在同一 session 內 | [agent-teams](https://github.com/githubhjs/chipagent-mod-agent-teams) | 不開新行程，用 subagent |
| 探索／設計／審查一個功能 | [feature-dev](https://github.com/githubhjs/chipagent-mod-feature-dev) | 平行探索再設計 |

關鍵差別：[chip-swarm](https://github.com/githubhjs/chipagent-mod-swarm) 開的是**真的獨立行程**，每隊有自己的 context，結果由腳本判定；agent-teams 和 feature-dev 在當前 session 內跑，共用同一份 context。

chip-swarm 是 CLI，不是 plugin：它沒有 marketplace.json 也沒有 plugin.json，把 `bin/chip-swarm` 放進 `PATH` 就好。agent-teams 和 feature-dev 是 Claude 格式的 plugin，用 `--type claude` 安裝。

### 開跑前要兩個檔案

- repo 根目錄的 `.chip-swarm.conf`（bash 語法）。`AGENT_ARGV` 開頭請用你 session 所用那支 ChipAgents 的**絕對路徑**（實測環境是 0.42.3），不要用 `PATH` 上第一支 `chipagents`：實測環境裡那支是 0.20.2，它裝 plugin 時也不會寫入 hook metadata。
- `.chipagents/verify.sh` 負責判定成敗，可以是 untracked：chip-swarm 會把未追蹤的 `.chipagents/` 複製進每個 worktree。**絕對不要放在 `~/.chipagents/`**，那會卡住你每一個 session。

## 為什麼要另外做一個 runner

- Claude Code 的 agent team plugin 依賴 Claude 專用的工具（`TeamCreate`、`SendMessage`、共用的 task list），ChipAgents 沒有這些。
- ChipAgents 的 subagent 都在同一個 session 裡跑。`chip-swarm` 提供的是**行程層級**的平行：每個 team 有獨立的 context 和獨立的 worktree，不會互相蓋掉檔案。
- 由你的 verify script **客觀判定**結果，不是聽 team 自己說「做完了」。

## 安裝

```bash
git clone https://github.com/githubhjs/chipagent-mod-swarm.git
sudo install -m 0755 chipagent-mod-swarm/bin/chip-swarm /usr/local/bin/
cd <你的 repo>
cp /path/to/chipagent-mod-swarm/chip-swarm.conf.example .chip-swarm.conf   # 調整 --allow-edits
bash /path/to/chipagent-mod-swarm/tests/selftest.sh                          # 用模擬 agent 跑 22 項檢查
```

- **不是用 git 取得檔案**（例如經過 VM 共用資料夾複製）時，執行權限會遺失。請用 `chmod +x bin/chip-swarm tests/chipagents tests/selftest.sh` 補回。self-test 本身不需要執行權限。
- **self-test 的暫存位置**：工作目錄建在 `$TMPDIR` 底下（預設 `/tmp`），要放到別處請設定 `TMPDIR`。

batch mode 有兩個限制：
- 只能執行 `.chipagents/automatic-commands.toml` 列出的 shell 指令。範本見 [chipagents-loop-kit](https://github.com/githubhjs/chipagents-loop-kit/blob/main/outer-loop/automatic-commands.toml.example)。
- 只能修改符合 `--allow-edits` 的檔案。

使用前先用互動模式 `chipagents` 執行一次 `/login`。

## 使用方式

### race：多 team 分路競速

```bash
chip-swarm race -n 3 task.md                 # 等全部跑完，選最佳且通過驗證的 team
chip-swarm race -n 3 --first task.md         # 最先通過的 team 勝出，其他 team 立刻停止
chip-swarm race -n 3 --merge task.md         # 另外把勝出的 team merge 進目前的 branch
chip-swarm race -n 2 --strategies strategies.txt task.md
```

- **策略**：每個 team 分到一個策略，`--strategies` 檔一行一個。沒指定時有三個預設：最小改動、最乾淨的設計、測試先行。
- **不同參數**：`.chip-swarm.conf` 的 `TEAM_EXTRA_ARGS` 可以讓各 team 用不同參數，例如 `"--thinking high"` 和 `"--thinking max"`，或不同的 `--provider`。
- **跑完之後**：chip-swarm 把每個 team 的修改 commit 到它的 branch `swarm/<run>/team-<k>`，並在它的 worktree 裡跑 `.chipagents/verify.sh`。
- **勝出條件**：必須通過驗證；通過的 team 中，改動行數最少者勝，同分再比 token 用量最少。加 `--first` 時，最先通過的 team 勝出，其他 team 的整個行程樹會被停止。
- **自動 merge**：`--merge` 用 `git merge --no-ff` 合併勝出者。有安裝 [git-flock-kit](https://github.com/githubhjs/git-flock-kit) 時會透過 `git flock` 執行。
- **結束碼**：有 team 通過時是 0。全部失敗時是 1，worktree 會保留下來供檢查。

### investigate：多 team 獨立調查再合流

```bash
cat > hypotheses.txt <<'EOF'
H1: the RX FIFO overflows because wr_en ignores full
H2: the testbench drives data one cycle late
H3: reset is released before the clock is stable
EOF
chip-swarm investigate -j 3 hypotheses.txt bug.md
```

- **每個假設一個調查員**，平行執行。每個調查員都必須蒐集**支持和反對**自己假設的證據，最後輸出這四項：
  - `VERDICT`
  - `CONFIDENCE`
  - `EVIDENCE`：file:line、log 行或 signal@time
  - `WHAT WOULD SETTLE IT`
- **唯讀**：調查員和最後的合併 run 都是唯讀的。chip-swarm 會從它們的指令裡拿掉 `--allow-edits`，所以 batch mode 改不了任何檔案。
- **合併**：最後一個合併 run 讀完所有報告，寫出 `VERDICT.md`，內容包括：
  - 哪些假設成立
  - 報告之間的矛盾
  - 最可能的解釋和信心度
  - 下一步
- **`--worktrees`**：給每個調查員獨立的 worktree，適合會寫出 build 或模擬輸出的檢查。

### fanout：多個任務平行跑

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

每個任務都在自己的 worktree 和 branch（`swarm/<run>/task-<k>`）裡執行，跑完後驗證並 commit。不會自動 merge，請自己 review 後再 merge 需要的 branch。只要有任何任務失敗，結束碼就是 1。

### clean

```bash
chip-swarm clean                 # 移除所有 chip-swarm 的 worktree 和 branch
chip-swarm clean race-20261020   # 只移除 run id 以此開頭的
```

## 檔案放在哪裡

worktree、prompt、log、報告和總表都放在 `../.chip-swarm/<repo 名稱>/<run id>/`。這個位置在 repo 外面，可以用 `SWARM_DIR` 改：

```
<run id>/
├── swarm.log
├── SUMMARY.md            race / fanout 的總表
├── VERDICT.md            investigate 的結論
└── team-<k>/
    ├── wt/               這個 team 的 git worktree
    ├── prompt.md         交給 team 的完整 prompt
    ├── response.txt / report.md
    ├── agent.log, verify.log, stats.json
    └── result
```

如果 `.chipagents/`（verify.sh、rules、skills、指令允許清單）沒有被 git 追蹤，會自動複製到每個 worktree，讓設定在那裡同樣生效。

## team run 裡的 workspace hook

每一次 `chipagents batch` 都會載入 workspace 的 hook（已在 ChipAgents 0.42.3 實測），所以 [chipagents-loop-kit](https://github.com/githubhjs/chipagents-loop-kit) 和 [claude-self-review-kit](https://github.com/githubhjs/claude-self-review-kit) 的關卡在每個 team 裡都會生效：

- **race 和 fanout 的 team** 保留這些關卡：goal-gate、verify-gate、review-gate 會讓每個 team 先完成並驗證自己的工作，chip-swarm 再來評判。
- **investigate 和合併 run** 是唯讀的，所以 chip-swarm 啟動它們時會帶 `CHIPAGENTS_HOOKS_INNER=1`（以及 `REVIEW_GATE_INNER=1`）。這些關卡會跳過這種 run，不會去推一個本來就不能改檔案的調查員。
- 重跑額度用的是 workspace 的 `post_turn_restarts`；重跑次數 = 這個值 − 1。

## 成本與安全

- **成本**：N 個 team 大約花 N 倍 token。`stats.json` 記錄每個 team 的用量，總表也會顯示。
- **`--skip-permissions`**：照 ChipAgents 文件的說法，只能在隔離的 sandbox 或 container 裡用。
- **team 之間看不到彼此的工作**：共用的介面和 contract 必須在 fan-out 之前就定好，不能在執行中協調。

## 實跑紀錄：ChipAgents 0.42.3（2026-10-20）

由 Josh_HUANG 在 CentOS 8 機器上以真的 `chipagents batch` 執行。底下每一個數字都來自真的跑過的指令。

| 模式 | 結果 | 耗時 |
|---|---|---|
| `race -n 2 --merge` | rc=0，team-2 勝出並合併 | 1m47s |
| `investigate -j 2` | rc=0，VERDICT 38 行 | 2m23s |
| `fanout -j 2` | rc=0，2/2，產生 2 個 branch | 47.7s |

```bash
chip-swarm race        -n 2 --merge task.md
chip-swarm investigate -j 2 hyp.txt bug.md
chip-swarm fanout      -j 2 tasks.txt
chip-swarm clean       [RUN_ID]
```

race 的實際 log：

```
11:01:35  team 1 started: Make the smallest change that satisfies...
11:01:35  team 2 started: Prefer the cleanest, most maintainable...
11:03:22  winner: swarm/race-20261020-110135/team-2
11:03:23  merged ... into master
```

預設挑最佳的通過隊伍（diff 最小，再比 token）；`--first` 是第一個通過就停掉其他隊；`--merge` 直接合併勝者，不加就印出 `git merge` 指令讓你自己決定。

### investigate 是最被低估的一個

每個假設一個**唯讀**調查者（拿不到 `--allow-edits`，改不了任何東西），最後一個合流裁決。拿一個故意寫壞的 4 行 `fifo.v` 測：

```
H1: cnt has no reset, so it starts X
H2: cnt wraps silently at 15
```

裁決做了最關鍵的一件事——**它自己重讀了 fifo.v，沒有照單全收報告**：

```
自行覆核：已讀 fifo.v 全文（4 行），與兩份報告引用完全一致。
H1 無 reset，上電為 X          -> SUPPORTED
H2 在 15 靜默 wrap             -> 現象為真，作為根因 REFUTED
報告衝突：無實質衝突。最可能解釋 — 信心 95
```

注意 H2 的判法：行為確實存在，但**作為根因**被否決。單一 agent 很容易把這兩件事混為一談，這正是分頭查證再合流的價值。

需要跑 build 或模擬的假設，加 `--worktrees` 給它自己的工作目錄。

### 已知問題

1. **執行位元會在傳輸中掉。** 經 VM 共用資料夾複製後，三個檔案沒有 x 位元，self-test 在開跑前就死掉：`chmod +x bin/chip-swarm tests/chipagents tests/selftest.sh`。在這個 repo 裡修權限（這裡已記錄為 100755）解決不了這條路徑。self-test 現在會自己複製 mock 並設定執行位元。
2. **self-test 不穩定：已修正。** 在那台機器上 8 次執行中，「race --merge: winner merged」失敗 7 次、「race: exits 1 when no team passes」失敗 3 次；同一個 race --merge 情境放到乾淨的隔離 fixture 跑則 4 次全過，真實 race 也成功，所以問題指向 self-test 的 fixture。根因（之後找到，修正於 `ac64f10`）：run id 只有時間戳，self-test 各案例共用同一個 `SWARM_DIR`，同一秒內啟動的下一個 race 會沿用前一個的目錄，死在 `git worktree add`（exit 64）。「多個 `new_repo` 共用 `$work` 導致 `.chip-swarm` 互相干擾」這個假設在機器上被推翻，是因為 self-test 的 `SWARM_DIR` 是 `$work/swarm`，根本不叫 `.chip-swarm`。現在 run id 帶 process id、以原子 `mkdir` 取得，每個案例有自己的 `SWARM_DIR`，另有回歸測試同時啟動三個 race（舊版會失敗）。這個修正已在 Git Bash 重現並驗證，尚未在 CentOS 上重跑。
3. self-test 用 `mktemp -d`，會落在 `/tmp`；不允許用 `/tmp` 的環境請設 `TMPDIR`。

### 沒有驗證的事

- ChipAgents 是否同時跑多個 subagent。已測事實：subagent 的回合**會**觸發 `post_turn` hook，但**不會**出現在 run log，只能靠副作用觀察；並行度本身沒測。這影響 agent-teams 與 feature-dev；chip-swarm 的每隊是獨立行程，不受影響。
- agent-teams 與 feature-dev：見各自 README 的實跑紀錄。

## 測試狀態

**在真正的 ChipAgents 0.42.3 上**：見上方[實跑紀錄](#實跑紀錄chipagents-0423-2026-10-20)。

`tests/selftest.sh` 用一個照 Batch Mode 文件寫的模擬 `chipagents batch`，跑 22 項檢查，涵蓋：
- best-of-N 的選擇
- 各 team 的不同參數
- `--first` 停止較慢的 team
- 全部失敗
- `--merge`
- 唯讀調查員、合併結論和 inner 旗標
- 有任務失敗的 fanout
- `clean`
- 三個 race 同時啟動、共用同一個 `SWARM_DIR`

在 Windows 的 Git Bash 全部通過。

最後一項檢查防的是一個已修正的 bug：
- 以前 run id 只有時間戳，在快的機器上，同一秒內啟動的下一個 run 會沿用上一個的目錄，結果在 `git worktree add` 失敗。
- 在 CentOS 上，這讓 `race --merge` 在 8 次 self-test 中失敗 7 次、「全部失敗」失敗 3 次（見上方已知問題）。
- 現在 run id 會帶上 process id，並用不可分割的 `mkdir` 佔用目錄。

## 相關 repo

- [chipagent-mod-agent-teams](https://github.com/githubhjs/chipagent-mod-agent-teams)：用 ChipAgents subagent 做 team review、假設驅動的除錯和協調的功能開發；需要行程層級平行時搭配 chip-swarm
- [chipagent-mod-feature-dev](https://github.com/githubhjs/chipagent-mod-feature-dev)：Anthropic 的 feature-dev 流程（平行的 explorer、architect、reviewer）的 ChipAgents 版
- [chipagents-loop-kit](https://github.com/githubhjs/chipagents-loop-kit)：讓單一 agent 在目標完成前不停
- [git-flock-kit](https://github.com/githubhjs/git-flock-kit)：多個 agent 共用一個工作目錄時，序列化 git commit

## 評估過但沒有移植的專案

| 專案 | 原因 |
|---|---|
| [ruvnet/ruflo](https://github.com/ruvnet/ruflo)（原 claude-flow，★77k） | swarm、hive-mind 工具只記錄狀態，實際工作仍由主 agent 做；原生模組需要 glibc 2.29/2.34（CentOS 8 是 2.28）；預設會自動安裝 npm 更新；它的 worker 模式是啟動 `claude` CLI |
| [Yeachan-Heo/oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode)（★40k） | 建立在 Claude Code 自己的 team 工具和 hooks 上；約 100 MB 的 TypeScript |
| [affaan-m/claude-swarm](https://github.com/affaan-m/claude-swarm) | 需要 Claude Agent SDK |
| [am-will/swarms](https://github.com/am-will/swarms) | 沒有授權條款，不能散布 |

## 授權

MIT，見 [LICENSE](LICENSE)。

## 作者

Chih-Hsueh "Josh" HUANG
