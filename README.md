# Worktree Sweeper

A small SwiftUI app that lists a repository's git worktrees, local branches and stashes, judges whether each is safe to delete, and removes them on request.

## Run

```bash
swift run
```

Print the same audit as text without opening a window:

```bash
swift run WorktreeSweeper --audit /path/to/repo
```

Build a double-clickable app (`dist/Worktree Sweeper.app`, ad-hoc signed):

```bash
./make-app.sh
```

Drop an `icon.icns` next to `make-app.sh` to give it an icon.

Run the verdict tests:

```bash
swift test
```

## Layout

| File              | Holds                                                                 |
|-------------------|-----------------------------------------------------------------------|
| `Shell.swift`     | Runs `git`, `gh`, `lsof`, `du` and returns their output                |
| `Models.swift`    | `Verdict`, `PullRequest`, `BranchStatus`, `Worktree`, `LocalBranch`, `Stash`, date helpers |
| `Auditor.swift`   | Discovers items, gathers facts, performs removals                      |
| `Judge.swift`     | Pure verdict rules, covered by `Tests/JudgeTests.swift`                |
| `Model.swift`     | `SweeperModel`: per-tab loading, disk sizes, confirmations             |
| `Views.swift`     | The window, three tables, status icon and badge                        |
| `App.swift`       | Entry point, About panel, `--audit` text mode                          |

## What it checks

Each refresh runs `git fetch --prune` first. Pull requests come from one bulk `gh pr list` of the last 1000, with a per-branch lookup for anything older.

Rows appear as soon as `git` lists them; verdicts stream in once the auditor has fetched, listed processes and loaded pull requests.

Per branch or worktree:

- Pull request state, and whether the local tip is the commit that merged (or an ancestor of it, after fetching `refs/pull/N/head` if needed)
- Commits ahead of `origin/HEAD`, whether the branch is pushed, whether the remote was deleted
- Stash entries made on the branch
- Last commit date

Per worktree, additionally:

- Uncommitted files, ignoring `.vscode/settings.json` (edit `Auditor.ignoredDirtyPaths`)
- Processes whose working directory is inside it, from `lsof`
- Whether the folder still exists or git marks the entry prunable
- Disk usage from `du -sk`, loaded after the table appears

Per stash: the branch it was made on and whether that branch still exists, file count, and whether it is a lint-staged automatic backup.

## Verdicts

| Verdict   | Worktrees and branches                                              | Stashes                     | Trash button |
|-----------|----------------------------------------------------------------------|-----------------------------|--------------|
| Prunable  | Folder gone or git marks it prunable                                 |                             | no confirm   |
| Dead      | Fully merged, nothing uncommitted, no stash                          | lint-staged automatic backup | no confirm  |
| Near-dead | Merged but with leftovers, or has commits the merged PR did not      | Its branch no longer exists | confirm      |
| Stale     | Unmerged and no activity for 14 days                                 | Older than 30 days          | confirm      |
| In use    | A process is working in the worktree, or the branch is checked out   |                             | confirm      |
| Active    | Open PR, uncommitted work, or recent unmerged commits                | Recent                      | confirm      |
| Main      | The primary checkout or default branch                               |                             | never        |

Removing a worktree runs `git worktree remove --force` (or `git worktree prune` when the folder is gone) and then `git branch -D`. Deleting a branch runs `git branch -D`. Dropping a stash always asks first and locates the stash by SHA at that moment.
