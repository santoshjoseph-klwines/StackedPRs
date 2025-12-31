# Stacked Pull Requests - PowerShell Implementation

This is a PowerShell implementation of [spr](https://github.com/ejoffe/spr) (Stacked Pull Requests).

## Overview

`git-spr.ps1` is a PowerShell script that manages stacked pull requests on GitHub. Each commit in your local branch becomes a pull request automatically, allowing you to work with a streamlined stacked diff workflow.

## Key Features

1. **Automatic PR Creation** - Each commit becomes a pull request automatically
2. **No Extra Commits** - Pushes specific commits directly to branches (no rebasing of branches)
3. **Automatic Commit-IDs** - Adds commit-ids to commits automatically
4. **Stack Management** - Automatically manages the PR stack and dependencies

## Requirements

- PowerShell 5.1 or later
- Git
- GitHub CLI (`gh`) - [Installation](https://cli.github.com/)

## Installation

1. The script is in this directory: `git-spr.ps1`
2. You can use it from any repository by referencing the full path, or add this directory to your PATH

## Usage

### Update/Create Pull Requests

```powershell
# Update all commits in stack
.\git-spr.ps1 update

# Update only first 2 commits
.\git-spr.ps1 update --count 2

# Add reviewers to new PRs
.\git-spr.ps1 update --reviewer username1 --reviewer username2
```

### Show Status

```powershell
.\git-spr.ps1 status

# With detailed output
.\git-spr.ps1 status --detail
```

### Merge Pull Requests

```powershell
# Merge all mergeable PRs
.\git-spr.ps1 merge

# Merge only first 2 PRs
.\git-spr.ps1 merge --count 2
```

### Amend a Commit

```powershell
# Stage your changes first
git add your-file.txt

# Run amend and choose which commit to amend
.\git-spr.ps1 amend
```

### Sync Local Stack

```powershell
# Synchronize local commits with remote PRs
.\git-spr.ps1 sync
```

## How It Works

1. **Commit IDs**: The script automatically adds `commit-id: xxxxxxxx` to commits that don't have them when you run `update`. You don't need to specify commit-ids when creating commits!

2. **Branch Naming**: Each commit gets a branch named `spr/{baseBranch}/{commitID}`. For example: `spr/main/abc12345`

3. **Pushing**: Instead of rebasing branches, the script pushes commits directly using:
   ```bash
   git push --force --atomic origin commitHash:refs/heads/branchName
   ```

4. **PR Stacking**: Each PR's base branch is the previous commit's branch (or the target branch for the first commit).

## Workflow Example

```powershell
# 1. Make commits normally (commit-ids will be added automatically)
git commit -m "Feature 1"
git commit -m "Feature 2"

# 2. Update to create/update PRs (this will automatically add commit-ids if missing)
.\git-spr.ps1 update

# 3. Check status
.\git-spr.ps1 status

# 4. When ready, merge all mergeable PRs
.\git-spr.ps1 merge
```

## Configuration

The script will look for a `.spr.yml` file in the repository root. Example:

```yaml
githubRemote: origin
githubBranch: main
requireChecks: true
requireApproval: true
mergeMethod: rebase
showPRLink: true
statusBitsEmojis: true
```

## Troubleshooting

### GitHub CLI not authenticated

Make sure you're authenticated with GitHub CLI:
```powershell
gh auth login
```

### Commits don't have commit-ids

The script automatically adds commit-ids to commits that don't have them when you run `update`. You don't need to do anything manually!

## Notes

- This is a PowerShell implementation of the Go-based `spr` tool
- The script requires commits to be in a linear stack (no merges in the stack)
- For full feature parity with the original tool, consider using the Go-based `spr` tool
