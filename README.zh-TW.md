# chipagent-mod-swarm：多個 ChipAgents team 平行跑

[English](README.md) | 繁體中文

`chip-swarm` 會同時跑好幾個非互動的 ChipAgents（`chipagents batch`），每個 team 有自己的 git worktree，最後把結果整合起來。Claude Code 使用者用 agent team、swarm 類 plugin 做到的多 team 模式，用它就能在 ChipAgents 上做到：

| 模式 | 用途 | 得到什麼 |
|---|---|---|
| `race` | **多 team 分路競速**：N 個 team 用不同策略（或不同模型、thinking 等級）解同一個任務 | 通過 `.chipagents/verify.sh` 的最佳 team；加 `--first` 則取最先通過的；可自動 merge |
| `investigate` | **多 team 獨立調查再合流**：每個假設一個唯讀調查員 | 每個假設一份報告，加上合併後的 `VERDICT.md` |
| `fanout` | **多個任務平行跑**（batch map） | 每個任務一個驗證過的 branch，加一張總表 |

整個工具就是一支 bash script，只需要 bash 4.4、git 和 coreutils，不需要 jq。它是為 CentOS 8 寫的，在 Git Bash 也能跑。

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
bash /path/to/chipagent-mod-swarm/tests/selftest.sh                          # 用模擬 agent 跑 19 項檢查
```

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

## 測試狀態

`tests/selftest.sh` 用一個照 Batch Mode 文件寫的模擬 `chipagents batch`，跑 19 項檢查，涵蓋：
- best-of-N 的選擇
- 各 team 的不同參數
- `--first` 停止較慢的 team
- 全部失敗
- `--merge`
- 唯讀調查員和合併結論
- 有任務失敗的 fanout
- `clean`

在 Windows 的 Git Bash 全部通過。**還沒有在真正的 ChipAgents 上跑過**；請先跑 self-test，再跑一次小規模的真實 race。

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
