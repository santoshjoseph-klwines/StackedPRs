# Stacked Pull Requests Helper

A PowerShell script to manage stacked pull requests with Git and GitHub CLI. This tool helps you create, update, and merge dependent pull requests efficiently.

## What are Stacked PRs?

Stacked PRs are a workflow where multiple pull requests depend on each other in a chain. For example:
- `feature-1` → based on `main`
- `feature-2` → based on `feature-1`
- `feature-3` → based on `feature-2`

This allows you to:
- Break large features into smaller, reviewable chunks
- Get early feedback on foundational changes
- Merge PRs independently as they're approved
- Keep your work organized and easy to track

## Prerequisites

- Git installed and configured
- GitHub CLI (`gh`) installed and authenticated
- PowerShell (Windows or PowerShell Core)

### Setup

1. **Authenticate with GitHub:**
   ```powershell
   gh auth login
   ```

2. **Check execution policy (if needed):**
   ```powershell
   Get-ExecutionPolicy
   # If restricted, run:
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
   ```

## Complete Workflow Example

Here's a typical workflow from start to finish:

### Step 1: Create Your First Feature Branch and PR

```powershell
# Start from main/master
git checkout main
git pull origin main

# Create feature-1 branch and PR
.\stacked-pr.ps1 create feature-1 main
```

This will:
- Create the branch `feature-1` based on `main`
- Push it to remote
- Create a PR with an auto-generated title

### Step 2: Create Stacked Branches

```powershell
# Create feature-2 stacked on feature-1
.\stacked-pr.ps1 create feature-2 feature-1

# Create feature-3 stacked on feature-2
.\stacked-pr.ps1 create feature-3 feature-2
```

Now you have a stack:
- PR #1: `feature-1` → `main`
- PR #2: `feature-2` → `feature-1`
- PR #3: `feature-3` → `feature-2`

### Step 3: Make Changes and Update

When you make changes to `feature-1`:

```powershell
# Make your changes, commit, and push
git checkout feature-1
# ... make changes ...
git add .
git commit -m "Update feature-1"
git push

# Automatically update all dependent PRs
.\stacked-pr.ps1 update-from feature-1
```

This will:
- Find all PRs stacked above `feature-1` (feature-2, feature-3, etc.)
- Rebase them in the correct order
- Update their PRs on GitHub

### Step 4: Check Status

```powershell
# See all your PRs and their relationships
.\stacked-pr.ps1 status
```

### Step 5: Merge the Stack

Once all PRs are approved:

```powershell
# Merge all approved PRs in the stack into main
.\stacked-pr.ps1 merge-stack main
```

This will:
- Find all PRs in the stack
- Check if they're approved and mergeable
- Merge them in order (bottom to top)
- Ask for confirmation before proceeding

## Command Reference

### `create <branch-name> [base-branch]`

Create a new branch and PR. If `base-branch` is not specified, uses the current branch.

**Examples:**
```powershell
# Create feature-1 based on main
.\stacked-pr.ps1 create feature-1 main

# Create feature-2 based on feature-1 (assumes you're on feature-1)
.\stacked-pr.ps1 create feature-2 feature-1

# Create with custom title and body
.\stacked-pr.ps1 create feature-2 feature-1 -Title "My Feature" -Body "Description"
```

### `rebase <branch-name> [base-branch]`

Rebase a branch on top of another branch (or master/main if not specified).

**Examples:**
```powershell
# Rebase feature-2 on feature-1
.\stacked-pr.ps1 rebase feature-2 feature-1

# Rebase on master (default)
.\stacked-pr.ps1 rebase feature-2
```

### `update <branch-name>`

Update a PR after rebasing (pushes with `--force-with-lease`).

**Example:**
```powershell
# After manually rebasing, push the update
.\stacked-pr.ps1 update feature-2
```

### `update-from <branch-name>`

Automatically update all PRs stacked above the specified branch. This is the **recommended way** to update your stack.

**Example:**
```powershell
# If you modified feature-1, automatically update feature-2, feature-3, etc.
.\stacked-pr.ps1 update-from feature-1
```

**What it does:**
- Finds all PRs stacked above the specified branch
- Sorts them in dependency order (bottom to top)
- Rebases each one in the correct sequence
- Shows what will be updated and asks for confirmation

### `merge-stack [base-branch]`

Merge all approved PRs in a stack into the base branch (default: `master`).

**Examples:**
```powershell
# Merge all PRs in stack into main
.\stacked-pr.ps1 merge-stack main

# Merge into master (default)
.\stacked-pr.ps1 merge-stack
```

**What it does:**
- Finds all PRs in the stack based on the specified branch
- Checks if they're all approved and mergeable
- Merges them in order from bottom to top
- Shows status of each PR before merging
- Asks for confirmation before proceeding

**Note:** Only merges PRs that are approved and mergeable. If some aren't ready, it will warn you but allow you to proceed if you choose.

### `status`

Show status of all your open PRs and their relationships.

**Example:**
```powershell
.\stacked-pr.ps1 status
```

### `list`

List all your open PRs.

**Example:**
```powershell
.\stacked-pr.ps1 list
```

### `help`

Show the help message with all commands.

**Example:**
```powershell
.\stacked-pr.ps1 help
```

## Advanced Options

### Force Push

Use the `-Force` flag with caution. The script uses `--force-with-lease` by default for safety.

```powershell
.\stacked-pr.ps1 rebase feature-2 feature-1 -Force
.\stacked-pr.ps1 update-from feature-2 -Force
```

### Custom PR Title and Body

```powershell
.\stacked-pr.ps1 create feature-2 feature-1 -Title "My Feature Title" -Body "Detailed description"
```

## Tips & Best Practices

1. **Always use `update-from`** - Instead of manually rebasing each branch, use `.\stacked-pr.ps1 update-from <branch>` to automatically update all dependent PRs.

2. **Check PR status regularly** - Use `.\stacked-pr.ps1 status` to see branch relationships and ensure everything is in order.

3. **Rebase from bottom to top** - If you have feature-1, feature-2, feature-3 stacked, update them in order. The `update-from` command handles this automatically.

4. **Use `merge-stack` when all PRs are approved** - Automatically merge all PRs in your stack in the correct order.

5. **The script automatically handles:**
   - Checking out and updating base branches
   - Creating PRs with proper base branches
   - Safe force pushing with `--force-with-lease`
   - Finding and sorting dependent PRs in the correct order
   - Checking PR approval status before merging
   - Restoring your original branch after operations

6. **Stay on your branch** - The script now restores your original branch after `update-from` operations, so you stay where you started.

## Troubleshooting

### Script won't run

- Make sure you're in PowerShell (not CMD)
- Check execution policy: `Get-ExecutionPolicy`
- If restricted, run: `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser`

### Rebase conflicts

- The script will stop and let you resolve conflicts manually
- After resolving: `git add .` then `git rebase --continue`
- Then run: `.\stacked-pr.ps1 update <branch-name>`

### PR not found

- Make sure you're authenticated: `gh auth status`
- Check if branch is pushed: `git push -u origin <branch-name>`
- Verify the PR exists: `gh pr list --head <branch-name>`

### PR closed after force push

- GitHub sometimes closes PRs when branch history is rewritten
- The script will warn you if this happens
- You may need to create a new PR if the old one can't be reopened

### Merge stack fails

- Make sure all PRs are approved: Check each PR's review status
- Ensure all PRs are mergeable: Resolve any conflicts or wait for CI checks
- If a merge fails partway through, you can run `merge-stack` again - it will skip already-merged PRs

### "No commits between branches"

- This means the branch has no unique commits compared to its base
- Add a commit to the branch: make changes, commit, and push
- Then create or update the PR

## Manual Git Commands (If Needed)

If you prefer to do things manually or the script doesn't cover your use case:

### Create Stacked Branch Manually

```powershell
git checkout feature-1
git pull origin feature-1
git checkout -b feature-2
# Make changes
git add .
git commit -m "Feature 2 changes"
git push -u origin feature-2
```

### Create PR Manually

```powershell
gh pr create --title "Feature 2" --body "Description" --base feature-1 --head feature-2
```

### Rebase Manually

```powershell
git checkout feature-2
git fetch origin feature-1
git rebase origin/feature-1
git push --force-with-lease origin feature-2
```

## Advantages of This Approach

- ✅ No external dependencies (you already have git and gh)
- ✅ Full control over your workflow
- ✅ No code sent to external services
- ✅ Works perfectly on Windows
- ✅ Simple and transparent
- ✅ Automated workflow with the script
- ✅ Handles complex dependency chains automatically

## Getting Help

Run the help command to see all available options:

```powershell
.\stacked-pr.ps1 help
```

Or check the script's inline help for detailed command descriptions.
