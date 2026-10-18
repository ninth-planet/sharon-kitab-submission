# sharon-kitab-submission

<!-- np-org-rules:v1.1 (2026-10-19) — keep this block identical across repos; edit it in one place: ~/np-rules.md -->

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
- **Xcode 27 is the only Xcode** (build `27A266a` at `/Applications/Xcode.app` on the Studio). Pin the exact build; change it only in its own PR.

### Releases

- Production releases approve a **specific commit SHA**, not "current main".
- Repos that deploy on merge (tathaluth, sharon-web, moiwell, madar): treat every merge as a production deploy.

### Worktrees & disk

- Create worktrees under `~/Dev/ninth-planet/.worktrees/<branch>` and **remove them when the PR merges or closes** (`git worktree remove`). Never leave `node_modules`/`Pods`/build output in an abandoned worktree.
- Evidence, screenshots and recordings go to `_evidence/<date>-<topic>` and are archived (CLAUDE card / WD cloud) after 14 days.
- Weekly `~/auto-clean.sh` removes rebuildable caches and build folders in projects idle 30+ days.

### Notifications

- Owner email is for failures on the default branch only; everything else goes into the daily digest.

<!-- /np-org-rules -->
