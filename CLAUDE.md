# sharon-kitab-submission

<!-- np-org-rules:v1.2 (2026-10-21) — keep this block identical across repos; edit it in one place: ~/np-rules.md -->

## Ninth Planet — org operating rules (all agents, all repos, all devices)

Adopted by the owner on 2026-10-19 after an audit found 203 branches (26 with real unmerged work), ~96 GB of abandoned worktrees, and most CI-failure emails coming from agents debugging on CI.

### Branches & PRs

- One task = one branch `claude/<topic>` (or `codex/<topic>`) = one PR. Open the PR as a **draft on your first push**; no work lives outside a PR.
- Merge = **squash**, only when required checks are green. Branches auto-delete on merge. Never push to the default branch directly (rulesets enforce this).
- A branch with no PR after 14 days is reported by the weekly janitor and archived.
- Never base a PR on another feature branch unless it is explicitly stacked and says so in its body.

### CI

- Run the repo's tests/lint/typecheck **locally before pushing**. Do not debug by pushing repeatedly to CI.
- "Flaky" is not a root cause: fix the test (e.g. median + CI budget) — never skip or disable it.
- Self-hosted runners are persistent: no `actions/cache` for npm/Playwright/SwiftPM there; put the toolchain version in any cache key.
- **Xcode 27 is the only Xcode** (build `27A266a` at `/Applications/Xcode_27.0.app` on the Studio and the MacBook since 2026-10-21; `/Applications/Xcode.app` is the App Store copy, 27.1, and never CI's). Pin the exact build; change it only in its own PR.

### Releases

- Production releases approve a **specific commit SHA**, not "current main".
- Repos that deploy on merge (tathaluth, sharon-web, moiwell, madar): treat every merge as a production deploy.

### Worktrees & disk

- Create worktrees under `~/Dev/ninth-planet/.worktrees/<branch>` and **remove them when the PR merges or closes** (`git worktree remove`). Never leave `node_modules`/`Pods`/build output in an abandoned worktree.
- Evidence, screenshots and recordings go to `_evidence/<date>-<topic>` and are archived (CLAUDE card / WD cloud) after 14 days.
- Weekly `~/auto-clean.sh` removes rebuildable caches and build folders in projects idle 30+ days.

### Finish = clean up (added 2026-10-21, owner's rule — applies to every Claude account, Codex and every repo)

- A job is not done until its mess is gone. Before you report "done" (PR merged/closed, task finished or abandoned), you must:
  1. remove your git worktree(s) (`git worktree remove <path>`) and delete the local branch;
  2. delete build output you created there (`node_modules`, `Pods`, `build`, `.next`, `DerivedData`) — never in another session's tree;
  3. stop dev servers / watchers / `caffeinate` you started, close your Terminal tabs, unmount drives or shares you mounted;
  4. delete your scratch/temp files outside the repo; keep evidence only under `_evidence/<date>-<topic>`;
  5. list what you cleaned (and anything you deliberately left) in your final report.
- Never remove work that is not safe elsewhere: only clean worktrees whose every commit is on GitHub (or whose PR is merged), and never touch another session's files or long-running jobs.
- Safety net: `~/.local/bin/np-agent-cleanup` runs at every Claude Code session end and daily at 04:30 on both Macs (clean + pushed/merged worktrees and merged local branches only; report in `~/np/janitor-report.md`). It does not replace step 1–5.

### Notifications

- Owner email is for failures on the default branch only; everything else goes into the daily digest.

<!-- /np-org-rules -->
