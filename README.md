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

| File                     | Holds                                                                 |
|--------------------------|-----------------------------------------------------------------------|
| `Shell.swift`            | Runs `git`, `gh`, `lsof`, `du` and returns their output               |
| `Models.swift`           | `Verdict`, `PullRequest`, `BranchStatus`, `Worktree`, `LocalBranch`, `Stash`, date helpers |
| `Scanner.swift`          | `RepoScanner` / `RepoAuditor` protocols; `GitScanner` lists worktrees, branches, stashes |
| `Parsers.swift`          | Pure parsers for git and lsof output, covered by `Tests/ParserTests.swift` |
| `GitAuditor.swift`       | Gathers facts per item, judges, performs removals                     |
| `PullRequestCache.swift` | One bulk `gh pr list`, indexed by branch and head SHA                 |
| `Concurrency.swift`      | Bounded parallel map                                                  |
| `Judge.swift`            | Pure verdict rules, covered by `Tests/JudgeTests.swift`               |
| `Model.swift`            | `SweeperModel`: per-tab loading, disk sizes, confirmations; covered by `Tests/ModelTests.swift` with a fake scanner |
| `Views.swift`            | The window, three tables, status icon and badge                       |
| `App.swift`       | Entry point, About panel, `--audit` text mode                          |

## What it checks

Each refresh runs `git fetch --prune` first. Pull requests come from one bulk `gh pr list` of the last 1000, with a per-branch lookup for anything older.

Rows appear as soon as `git` lists them; verdicts stream in once the auditor has fetched, listed processes and loaded pull requests.

Per branch or worktree:

- Pull request state, and whether the local tip is the commit that merged (or an ancestor of it, after fetching `refs/pull/N/head` into `refs/sweeper/pull/N` if needed). Detached worktrees match PRs by commit SHA.
- Commits ahead of `origin/HEAD`, whether the branch is pushed, whether the remote was deleted
- Stash entries made on the branch (shown as a note only; a stash keeps its base commit, so deleting the branch loses nothing)
- Last commit date

Per worktree, additionally:

- Uncommitted files, ignoring `.vscode/settings.json` (edit `GitAuditor.ignoredDirtyPaths`)
- Processes whose working directory is inside it, from `lsof`
- Whether the folder still exists or git marks the entry prunable
- Folder creation time, shown as Added and the default sort
- Disk usage from `du -sk`, loaded after the table appears

Per stash: the branch it was made on and whether that branch still exists, file count, whether it is a lint-staged automatic backup, and how it compares to main. The "vs main" column says `in main` when main already contains every change, `not in main` when main has none of it and the whole stash would still apply cleanly, `conflicts` when main has changed around every file, or a per-file count otherwise (`7 of 29 in main`); the preview pane tags each file. The check reads a private index of `origin/main` built with `git read-tree` into a file under the temp folder (`GIT_INDEX_FILE`), then runs `git apply --check --cached` forward and reversed on the stash's patch, per file where the whole patch is mixed. `--check` only reads, so the repo's index, working trees and refs are never written. Every git call also runs with `GIT_OPTIONAL_LOCKS=0`, so `git status` does not refresh the index either.

Selecting a stash opens a preview pane on the right with each file's added and removed line counts, its vs-main tag, and the full diff (`git diff <sha>^1 <sha>`, so untracked files stashed with `-u` are not shown). It has Copy patch, Open patch (writes a `.patch` to the temp folder and opens it with its default app) and Drop buttons. The sidebar button next to Rescan hides it.

## Verdicts

| Verdict   | Worktrees and branches                                              | Stashes                     | Trash button |
|-----------|----------------------------------------------------------------------|-----------------------------|--------------|
| Prunable  | Folder gone or git marks it prunable                                 |                             | no confirm   |
| Dead      | Fully merged and nothing uncommitted                                 | lint-staged automatic backup, or every file already in main | no confirm  |
| Near-dead | Merged but with uncommitted files, or has commits the merged PR did not | Its branch no longer exists | confirm   |
| Stale     | Unmerged and no activity for 14 days                                 | Older than 30 days          | confirm      |
| In use    | A process is working in the worktree, or the branch is checked out   |                             | confirm      |
| Active    | Open PR, uncommitted work, recent unmerged commits, or a folder added in the last day with no commits of its own | Recent | confirm |
| Main      | The primary checkout or default branch                               |                             | never        |

Removing a Dead worktree runs plain `git worktree remove` so git's own cleanliness check is a second guard; anything confirmed through the dialog uses `--force`. The branch is then deleted with `git branch -d` when git can see the merge in history, or `-D` for squash merges and confirmed deletes. Dropping a stash always asks first and locates the stash by SHA at that moment.

After a delete the footer shows the commit it pointed at and a copy button for the `git branch` or `git stash store` command that brings it back. Deleting after a scan older than 20 minutes asks for a rescan first. If `git fetch` or `gh pr list` fails, the footer says so, because squash-merged branches then look unmerged.

The Delete key removes the selected row, with the same confirmation rules as the trash button.
