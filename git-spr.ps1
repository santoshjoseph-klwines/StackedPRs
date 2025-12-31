# Stacked Pull Requests PowerShell Script
# Based on https://github.com/ejoffe/spr
# Usage: .\git-spr.ps1 <command> [options]

param(
    [Parameter(Position = 0)]
    [ValidateSet("update", "status", "merge", "sync", "amend", "help")]
    [string]$Command = "help",
    
    [Parameter(Position = 1)]
    [uint]$Count = 0,
    
    [string[]]$Reviewer = @(),
    
    [switch]$Detail,
    [switch]$NoRebase
)

$ErrorActionPreference = "Stop"

# Configuration
$Config = @{
    GitHubRemote = "origin"
    GitHubBranch = "main"
    GitHubHost = "github.com"
    RequireChecks = $true
    RequireApproval = $true
    MergeMethod = "rebase"
    ShowPRLink = $true
    LogGitCommands = $true
    LogGitHubCalls = $true
    StatusBitsEmojis = $true
    StatusBitsHeader = $true
}

function Show-Help {
    Write-Host @"
Stacked Pull Requests - PowerShell implementation of spr

USAGE:
    .\git-spr.ps1 <command> [options]

COMMANDS:
    update [--count N] [--reviewer USER]
        Update and create pull requests for commits in the stack.
        Each commit becomes a pull request. Commits must have 'commit-id: xxxxxxxx' in the message.
        
    status [--detail]
        Show status of all open pull requests in the stack.
        
    merge [--count N]
        Merge all mergeable pull requests from the bottom of the stack.
        
    sync
        Synchronize local stack with remote (cherry-pick commits from remote PRs).
        
    amend
        Amend a commit in the stack. Lists commits and lets you choose which one to amend.
        Stage your changes first with 'git add', then run 'amend'.
        
    help
        Show this help message.

OPTIONS:
    --count N          Update or merge only N pull requests from the bottom
    --reviewer USER    Add reviewer to newly created pull requests (can be specified multiple times)
    --detail           Show detailed status bits output
    --no-rebase        Skip rebasing on update (use SPR_NOREBASE env var)

EXAMPLES:
    # Update all commits in stack to create/update PRs
    .\git-spr.ps1 update
    
    # Update only first 2 commits
    .\git-spr.ps1 update --count 2
    
    # Show status
    .\git-spr.ps1 status
    
    # Merge all mergeable PRs
    .\git-spr.ps1 merge
"@
}

function ConvertFrom-Yaml {
    param([string]$YamlContent)
    
    # Simple YAML parser for basic key-value pairs
    $result = @{}
    $lines = $YamlContent -split "`n"
    
    foreach ($line in $lines) {
        $line = $line.Trim()
        if ($line -match '^([^:]+):\s*(.+)$' -and -not $line.StartsWith('#')) {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()
            
            # Remove quotes if present
            if ($value -match '^["''](.+)["'']$') {
                $value = $matches[1]
            }
            
            # Convert boolean strings
            if ($value -eq 'true') { $value = $true }
            elseif ($value -eq 'false') { $value = $false }
            
            $result[$key] = $value
        }
    }
    
    return $result
}

function Get-GitConfig {
    # Try to load config from .spr.yml in repo
    $repoConfigPath = Join-Path (Get-GitRoot) ".spr.yml"
    if (Test-Path $repoConfigPath) {
        try {
            $yamlContent = Get-Content $repoConfigPath -Raw
            $repoConfig = ConvertFrom-Yaml $yamlContent
            if ($repoConfig) {
                foreach ($key in $repoConfig.Keys) {
                    if ($Config.ContainsKey($key)) {
                        $Config[$key] = $repoConfig[$key]
                    }
                }
            }
        } catch {
            Write-Warning "Failed to parse .spr.yml: $_"
        }
    }
    
    # Get GitHub repo info from git remote
    $remoteUrl = git remote get-url $Config.GitHubRemote 2>$null
    if ($remoteUrl) {
        if ($remoteUrl -match 'github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?$') {
            $Config.GitHubRepoOwner = $matches[1]
            $Config.GitHubRepoName = $matches[2] -replace '\.git$', ''
        } elseif ($remoteUrl -match '([^/]+)/([^/]+?)(?:\.git)?$') {
            $Config.GitHubRepoOwner = $matches[1]
            $Config.GitHubRepoName = $matches[2] -replace '\.git$', ''
        }
    }
    
    # Detect default branch
    $defaultBranch = git symbolic-ref refs/remotes/$($Config.GitHubRemote)/HEAD 2>$null
    if ($defaultBranch) {
        $Config.GitHubBranch = $defaultBranch -replace "^refs/remotes/$($Config.GitHubRemote)/", ""
    }
}

function Get-GitRoot {
    $root = git rev-parse --show-toplevel 2>$null
    if (-not $root) {
        throw "Not in a git repository"
    }
    return $root
}

function Invoke-GitCommand {
    param(
        [string]$Command,
        [string]$Output = $null
    )
    
    if ($Config.LogGitCommands) {
        Write-Host "> git $Command" -ForegroundColor DarkGray
    }
    
    if ($Output) {
        $result = git $Command.Split(' ') 2>&1 | Out-String
        Set-Variable -Name $Output -Value $result -Scope 1
        return $LASTEXITCODE -eq 0
    } else {
        git $Command.Split(' ') 2>&1 | Out-Null
        return $LASTEXITCODE -eq 0
    }
}

function Add-CommitIDs {
    # Automatically add commit-ids to commits that don't have them using rebase
    $remoteBranch = "$($Config.GitHubRemote)/$($Config.GitHubBranch)"
    $baseCommit = git merge-base HEAD $remoteBranch 2>$null
    
    if (-not $baseCommit) {
        return $false
    }
    
    Write-Host "Adding commit-ids to commits that don't have them..." -ForegroundColor Cyan
    
    # Create editor script that adds commit-id to commit messages
    $editorScript = Join-Path $env:TEMP "git-spr-add-commit-id.ps1"
    $editorContent = @'
param($FilePath)

if ($FilePath -like "*COMMIT_EDITMSG*") {
    $content = Get-Content $FilePath -Raw
    if ($content -and $content -notmatch "commit-id:") {
        # Generate a new commit-id (8 hex chars)
        $commitID = [guid]::NewGuid().ToString().Replace('-', '').Substring(0, 8)
        
        # Ensure message ends with newline
        $content = $content.TrimEnd()
        if (-not $content.EndsWith("`n")) {
            $content += "`n"
        }
        
        # Add commit-id
        $content += "`ncommit-id: $commitID`n"
        
        # Write back
        [System.IO.File]::WriteAllText($FilePath, $content, [System.Text.Encoding]::UTF8)
    }
    exit 0
}
'@
    $editorContent | Out-File -FilePath $editorScript -Encoding utf8
    
    # Create sequence editor script that marks commits without IDs for reword
    $sequenceEditor = Join-Path $env:TEMP "git-spr-sequence-editor.ps1"
    $seqContent = @'
param($FilePath)
$content = Get-Content $FilePath
$newContent = @()
foreach ($line in $content) {
    if ($line -match '^pick ([a-f0-9]+)') {
        $hash = $matches[1]
        $msg = git log --format=%B -n 1 $hash 2>$null
        if ($msg -and $msg -notmatch 'commit-id:') {
            $newContent += $line -replace '^pick', 'reword'
        } else {
            $newContent += $line
        }
    } else {
        $newContent += $line
    }
}
$newContent | Out-File -FilePath $FilePath -Encoding utf8
'@
    $seqContent | Out-File -FilePath $sequenceEditor -Encoding utf8
    
    try {
        # Save original editors
        $originalEditor = $env:GIT_EDITOR
        $originalSeqEditor = $env:GIT_SEQUENCE_EDITOR
        
        # Set our custom editors
        $env:GIT_EDITOR = "powershell -File `"$editorScript`""
        $env:GIT_SEQUENCE_EDITOR = "powershell -File `"$sequenceEditor`""
        
        # Run interactive rebase (will be automated by our editors)
        $rebaseCmd = "rebase -i $baseCommit"
        if (-not (Invoke-GitCommand $rebaseCmd)) {
            Write-Host "Rebase to add commit-ids encountered issues. You may need to add commit-ids manually." -ForegroundColor Yellow
            return $false
        }
        
        Write-Host "✓ Successfully added commit-ids" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "Error adding commit-ids: $_" -ForegroundColor Red
        return $false
    } finally {
        # Restore original editors
        if ($originalEditor) {
            $env:GIT_EDITOR = $originalEditor
        } else {
            Remove-Item Env:\GIT_EDITOR -ErrorAction SilentlyContinue
        }
        if ($originalSeqEditor) {
            $env:GIT_SEQUENCE_EDITOR = $originalSeqEditor
        } else {
            Remove-Item Env:\GIT_SEQUENCE_EDITOR -ErrorAction SilentlyContinue
        }
        
        # Clean up temp files
        Remove-Item $editorScript -ErrorAction SilentlyContinue
        Remove-Item $sequenceEditor -ErrorAction SilentlyContinue
    }
}

function Get-LocalCommitStack {
    $remoteBranch = "$($Config.GitHubRemote)/$($Config.GitHubBranch)"
    
    # Check if remote branch exists
    $remoteExists = git ls-remote --heads $Config.GitHubRemote $Config.GitHubBranch 2>$null
    if (-not $remoteExists) {
        Write-Warning "Remote branch $remoteBranch does not exist. Using local commits only."
        $commitLog = ""
        Invoke-GitCommand "log --format=medium --no-color HEAD" -Output "commitLog" | Out-Null
    } else {
        # Get commits that are not in the remote branch
        $commitLog = ""
        if (-not (Invoke-GitCommand "log --format=medium --no-color $remoteBranch..HEAD" -Output "commitLog")) {
            return @()
        }
    }
    
    $commits = Parse-CommitLog $commitLog
    
    # Check if any commits are missing commit-ids
    $missingIDs = $commits | Where-Object { -not $_.CommitID }
    
    if ($missingIDs.Count -gt 0) {
        Write-Host "Some commits are missing commit-ids. Adding them automatically..." -ForegroundColor Yellow
        
        # Add commit-ids automatically
        if (Add-CommitIDs) {
            # Re-parse after adding IDs
            $commitLog = ""
            Invoke-GitCommand "log --format=medium --no-color $remoteBranch..HEAD" -Output "commitLog" | Out-Null
            $commits = Parse-CommitLog $commitLog
        } else {
            # Fallback: generate IDs from hash (not ideal, but works)
            foreach ($commit in $commits) {
                if (-not $commit.CommitID) {
                    $commit.CommitID = $commit.CommitHash.Substring(0, 8)
                    Write-Warning "Commit $($commit.CommitHash) missing commit-id, using hash prefix (will change if amended)"
                }
            }
        }
    }
    
    return $commits
}

function Parse-CommitLog {
    param([string]$CommitLog)
    
    $commits = @()
    $lines = $CommitLog -split "`n"
    
    $commitHashRegex = [regex]'^commit ([a-f0-9]{40})'
    $commitIDRegex = [regex]'commit-id:\s*([a-f0-9]{8})'
    
    $currentCommit = $null
    $commitScanOn = $false
    $subjectIndex = 0
    
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        
        # Match commit hash
        $hashMatch = $commitHashRegex.Match($line)
        if ($hashMatch.Success) {
            if ($commitScanOn) {
                # Previous commit missing commit-id - add it anyway with empty CommitID
                # We'll add the commit-id later
                $currentCommit.Body = $currentCommit.Body.Trim()
                if ($currentCommit.Subject -match '^WIP') {
                    $currentCommit.WIP = $true
                }
                # Prepend to maintain order (oldest first)
                $commits = @($currentCommit) + $commits
            }
            $commitScanOn = $true
            $currentCommit = @{
                CommitHash = $hashMatch.Groups[1].Value
                CommitID = ""
                Subject = ""
                Body = ""
                WIP = $false
            }
            $subjectIndex = $i + 4
            continue
        }
        
        # Match commit-id
        $idMatch = $commitIDRegex.Match($line)
        if ($idMatch.Success) {
            if (-not $commitScanOn) {
                continue
            }
            $currentCommit.CommitID = $idMatch.Groups[1].Value
            $currentCommit.Body = $currentCommit.Body.Trim()
            
            if ($currentCommit.Subject -match '^WIP') {
                $currentCommit.WIP = $true
            }
            
            # Prepend to maintain order (oldest first)
            $commits = @($currentCommit) + $commits
            $commitScanOn = $false
            $currentCommit = $null
            continue
        }
        
        # Collect subject and body
        if ($commitScanOn -and $currentCommit) {
            if ($i -eq $subjectIndex) {
                $currentCommit.Subject = $line.Trim()
            } elseif ($i -gt $subjectIndex) {
                if ($line.Trim() -ne "" -or $currentCommit.Body -ne "") {
                    $currentCommit.Body += $line.Trim() + "`n"
                }
            }
        }
    }
    
    if ($commitScanOn) {
        # Last commit missing commit-id - add it anyway with empty CommitID
        $currentCommit.Body = $currentCommit.Body.Trim()
        if ($currentCommit.Subject -match '^WIP') {
            $currentCommit.WIP = $true
        }
        # Prepend to maintain order (oldest first)
        $commits = @($currentCommit) + $commits
    }
    
    return $commits
}

function Get-BranchNameFromCommit {
    param([hashtable]$Commit)
    
    return "spr/$($Config.GitHubBranch)/$($Commit.CommitID)"
}

function Get-GitHubPRs {
    $prsJson = gh pr list --author "@me" --json "number,title,state,baseRefName,headRefName,url,isDraft,mergeable,reviewDecision,body" --limit 50 2>$null
    if (-not $prsJson) {
        return @()
    }
    
    $prs = $prsJson | ConvertFrom-Json | Where-Object { $_.state -eq "OPEN" }
    
    # Extract commit-id from PR body or branch name
    foreach ($pr in $prs) {
        # Try to extract commit-id from branch name (spr/{base}/{commitID})
        if ($pr.headRefName -match '^spr/[^/]+/([a-f0-9]{8})$') {
            $pr | Add-Member -NotePropertyName "CommitID" -NotePropertyValue $matches[1] -Force
        } else {
            $pr | Add-Member -NotePropertyName "CommitID" -NotePropertyValue "" -Force
        }
    }
    
    return $prs
}

function Sync-CommitStackToGitHub {
    param([array]$Commits, [array]$ExistingPRs)
    
    # Stash uncommitted changes
    $statusOutput = ""
    Invoke-GitCommand "status --porcelain --untracked-files=no" -Output "statusOutput" | Out-Null
    $hasUncommitted = $statusOutput.Trim() -ne ""
    
    if ($hasUncommitted) {
        Write-Host "Stashing uncommitted changes..." -ForegroundColor Yellow
        if (-not (Invoke-GitCommand "stash")) {
            return $false
        }
        $shouldPop = $true
    } else {
        $shouldPop = $false
    }
    
    try {
        # Find commits that need to be pushed
        $commitsToPush = @()
        $prMap = @{}
        foreach ($pr in $ExistingPRs) {
            if ($pr.CommitID) {
                $prMap[$pr.CommitID] = $pr
            }
        }
        
        foreach ($commit in $Commits) {
            if ($commit.WIP) {
                break
            }
            
            $needsPush = $true
            if ($prMap.ContainsKey($commit.CommitID)) {
                $pr = $prMap[$commit.CommitID]
                # Check if commit hash changed (commit was amended)
                $branchName = Get-BranchNameFromCommit $commit
                $remoteCommit = git rev-parse "refs/remotes/$($Config.GitHubRemote)/$branchName" 2>$null
                if ($remoteCommit -eq $commit.CommitHash) {
                    $needsPush = $false
                }
            }
            
            if ($needsPush) {
                $commitsToPush += $commit
            }
        }
        
        if ($commitsToPush.Count -eq 0) {
            Write-Host "No commits need to be pushed." -ForegroundColor Green
            return $true
        }
        
        # Push commits directly to branches using refspec
        Write-Host "Pushing $($commitsToPush.Count) commit(s) to GitHub..." -ForegroundColor Cyan
        
        $refSpecs = @()
        foreach ($commit in $commitsToPush) {
            $branchName = Get-BranchNameFromCommit $commit
            $refSpec = "$($commit.CommitHash):refs/heads/$branchName"
            $refSpecs += $refSpec
        }
        
        if ($Config.BranchPushIndividually) {
            foreach ($refSpec in $refSpecs) {
                $branchName = $refSpec -replace '^[^:]+:refs/heads/', ''
                Write-Host "  Pushing $branchName..." -ForegroundColor Gray
                if (-not (Invoke-GitCommand "push --force $($Config.GitHubRemote) $refSpec")) {
                    throw "Failed to push branch"
                }
            }
        } else {
            # Atomic push
            $pushCmd = "push --force --atomic $($Config.GitHubRemote) " + ($refSpecs -join " ")
            if (-not (Invoke-GitCommand $pushCmd)) {
                throw "Failed to push branches"
            }
        }
        
        Write-Host "✓ Successfully pushed commits" -ForegroundColor Green
        return $true
    } finally {
        if ($shouldPop) {
            Write-Host "Popping stash..." -ForegroundColor Yellow
            Invoke-GitCommand "stash pop" | Out-Null
        }
    }
}

function Update-PullRequests {
    param([array]$Reviewers = @())
    
    if (-not $NoRebase -and $env:SPR_NOREBASE -ne "1") {
        # Fetch and rebase on remote branch
        Write-Host "Fetching from $($Config.GitHubRemote)..." -ForegroundColor Cyan
        Invoke-GitCommand "fetch $($Config.GitHubRemote)" | Out-Null
        
        Write-Host "Rebasing on $($Config.GitHubRemote)/$($Config.GitHubBranch)..." -ForegroundColor Cyan
        if (-not (Invoke-GitCommand "rebase $($Config.GitHubRemote)/$($Config.GitHubBranch) --autostash")) {
            Write-Host "Rebase failed or had conflicts. Please resolve and try again." -ForegroundColor Red
            return
        }
    }
    
    # Get GitHub info
    $existingPRs = Get-GitHubPRs
    $localCommits = Get-LocalCommitStack
    
    if ($localCommits.Count -eq 0) {
        Write-Host "No local commits found." -ForegroundColor Yellow
        return
    }
    
    # Filter out WIP commits
    $commitsToProcess = $localCommits | Where-Object { -not $_.WIP }
    if ($Count -gt 0) {
        $commitsToProcess = $commitsToProcess[0..([Math]::Min($Count - 1, $commitsToProcess.Count - 1))]
    }
    
    # Close PRs for deleted commits
    $commitIDMap = @{}
    foreach ($commit in $commitsToProcess) {
        $commitIDMap[$commit.CommitID] = $commit
    }
    
    foreach ($pr in $existingPRs) {
        if ($pr.CommitID -and -not $commitIDMap.ContainsKey($pr.CommitID)) {
            Write-Host "Closing PR #$($pr.number): commit has gone away" -ForegroundColor Yellow
            gh pr comment $pr.number --body "Closing pull request: commit has gone away" 2>&1 | Out-Null
            gh pr close $pr.number 2>&1 | Out-Null
        }
    }
    
    # Sync commits to GitHub (push branches)
    if (-not (Sync-CommitStackToGitHub -Commits $commitsToProcess -ExistingPRs $existingPRs)) {
        return
    }
    
    # Create or update PRs
    $prMap = @{}
    foreach ($pr in $existingPRs) {
        if ($pr.CommitID) {
            $prMap[$pr.CommitID] = $pr
        }
    }
    
    # Build complete stack list for PR bodies
    $allStackPRs = @()
    foreach ($commit in $commitsToProcess) {
        if ($prMap.ContainsKey($commit.CommitID)) {
            $allStackPRs += $prMap[$commit.CommitID]
        }
    }
    
    $prevCommit = $null
    $prevPR = $null
    $createdPRs = @()
    
    foreach ($commit in $commitsToProcess) {
        $branchName = Get-BranchNameFromCommit $commit
        
        if ($prMap.ContainsKey($commit.CommitID)) {
            # Update existing PR
            $pr = $prMap[$commit.CommitID]
            $baseBranch = if ($prevCommit) { Get-BranchNameFromCommit $prevCommit } else { $Config.GitHubBranch }
            
            if ($pr.baseRefName -ne $baseBranch) {
                Write-Host "Updating PR #$($pr.number) base to $baseBranch..." -ForegroundColor Cyan
                gh pr edit $pr.number --base $baseBranch 2>&1 | Out-Null
            }
            
            # Update PR body with stack info
            $body = $commit.Body
            if ($allStackPRs.Count -gt 1 -or $createdPRs.Count -gt 0) {
                $stackMarkdown = "`n`n---`n`n**Stack**:`n"
                # Add existing PRs
                for ($i = $allStackPRs.Count - 1; $i -ge 0; $i--) {
                    $stackPR = $allStackPRs[$i]
                    $suffix = if ($stackPR.number -eq $pr.number) { " ⬅" } else { "" }
                    $stackMarkdown += "- #$($stackPR.number)$suffix`n"
                }
                # Add newly created PRs
                for ($i = $createdPRs.Count - 1; $i -ge 0; $i--) {
                    $stackPR = $createdPRs[$i]
                    $suffix = if ($stackPR.number -eq $pr.number) { " ⬅" } else { "" }
                    $stackMarkdown += "- #$($stackPR.number)$suffix`n"
                }
                $body += $stackMarkdown
                
                gh pr edit $pr.number --body $body 2>&1 | Out-Null
            }
            
            $prevPR = $pr
        } else {
            # Create new PR
            $baseBranch = if ($prevCommit) { Get-BranchNameFromCommit $prevCommit } else { $Config.GitHubBranch }
            
            Write-Host "Creating PR for commit $($commit.CommitID)..." -ForegroundColor Cyan
            if ($Config.LogGitHubCalls) {
                Write-Host "> github create : $($commit.Subject)" -ForegroundColor DarkGray
            }
            
            $body = $commit.Body
            # Build stack markdown - will be updated after PR creation
            if ($allStackPRs.Count -gt 0 -or $createdPRs.Count -gt 0) {
                $stackMarkdown = "`n`n---`n`n**Stack**:`n"
                foreach ($stackPR in $allStackPRs) {
                    $stackMarkdown += "- #$($stackPR.number)`n"
                }
                foreach ($stackPR in $createdPRs) {
                    $stackMarkdown += "- #$($stackPR.number)`n"
                }
                $stackMarkdown += "- #NEW ⬅`n"
                $body += $stackMarkdown
            } elseif ($prevCommit -and $prMap.ContainsKey($prevCommit.CommitID)) {
                $body += "`n`n---`n`n**Stack**:`n- #$($prMap[$prevCommit.CommitID].number)`n- #NEW ⬅`n"
            }
            
            $prOutput = gh pr create `
                --title $commit.Subject `
                --body $body `
                --base $baseBranch `
                --head $branchName `
                2>&1
            
            if ($LASTEXITCODE -eq 0) {
                # Get the created PR number
                Start-Sleep -Seconds 1
                $newPRJson = gh pr view $branchName --json number,title,headRefName 2>$null
                if ($newPRJson) {
                    $newPR = $newPRJson | ConvertFrom-Json
                    $newPR | Add-Member -NotePropertyName "CommitID" -NotePropertyValue $commit.CommitID -Force
                    $createdPRs += $newPR
                    $allStackPRs += $newPR
                    
                    # Update PR body to replace #NEW with actual PR number
                    $updatedBody = $body -replace '#NEW', "#$($newPR.number)"
                    gh pr edit $newPR.number --body $updatedBody 2>&1 | Out-Null
                    
                    if ($Reviewers.Count -gt 0) {
                        foreach ($reviewer in $Reviewers) {
                            gh pr edit $newPR.number --add-reviewer $reviewer 2>&1 | Out-Null
                        }
                    }
                    $prevPR = $newPR
                }
            } else {
                Write-Host "Failed to create PR: $prOutput" -ForegroundColor Red
            }
        }
        
        $prevCommit = $commit
    }
    
    # Show status
    Show-PRStatus
}

function Show-PRStatus {
    $prs = Get-GitHubPRs
    $localCommits = Get-LocalCommitStack | Where-Object { -not $_.WIP }
    
    if ($prs.Count -eq 0) {
        Write-Host "No open pull requests." -ForegroundColor Yellow
        return
    }
    
    # Match PRs to commits by commit-id
    $prByCommitID = @{}
    foreach ($pr in $prs) {
        if ($pr.CommitID) {
            $prByCommitID[$pr.CommitID] = $pr
        }
    }
    
    # Sort PRs by commit order (reverse for display - newest first)
    $sortedPRs = @()
    
    if ($localCommits.Count -gt 0) {
        # If we have local commits, match them to PRs
        for ($i = $localCommits.Count - 1; $i -ge 0; $i--) {
            $commit = $localCommits[$i]
            if ($prByCommitID.ContainsKey($commit.CommitID)) {
                $sortedPRs += $prByCommitID[$commit.CommitID]
            }
        }
    } else {
        # No local commits ahead of base branch - show all PRs anyway
        # Try to sort by PR number or base branch relationship
        $prsByBase = @{}
        foreach ($pr in $prs) {
            if (-not $prsByBase.ContainsKey($pr.baseRefName)) {
                $prsByBase[$pr.baseRefName] = @()
            }
            $prsByBase[$pr.baseRefName] += $pr
        }
        
        # Build stack: PRs that base on main first, then PRs that base on other PRs
        $processed = @{}
        function Add-PrToStack {
            param([string]$BaseBranch)
            if ($processed.ContainsKey($BaseBranch)) { return }
            $processed[$BaseBranch] = $true
            
            if ($prsByBase.ContainsKey($BaseBranch)) {
                foreach ($pr in $prsByBase[$BaseBranch]) {
                    if ($pr.CommitID -and -not ($sortedPRs | Where-Object { $_.number -eq $pr.number })) {
                        $sortedPRs += $pr
                        # Recursively add PRs that base on this PR
                        $prBranch = $pr.headRefName
                        Add-PrToStack -BaseBranch $prBranch
                    }
                }
            }
        }
        
        # Start with main branch
        Add-PrToStack -BaseBranch $Config.GitHubBranch
        
        # Add any remaining PRs
        foreach ($pr in $prs) {
            if (-not ($sortedPRs | Where-Object { $_.number -eq $pr.number })) {
                $sortedPRs += $pr
            }
        }
        
        # Reverse to show newest first
        $sortedPRs = $sortedPRs[($sortedPRs.Count-1)..0]
    }
    
    if ($sortedPRs.Count -eq 0) {
        Write-Host "No matching pull requests found." -ForegroundColor Yellow
        return
    }
    
    if ($Config.StatusBitsHeader) {
        Write-Host @"

 ┌─ github checks pass
 │ ┌── pull request approved
 │ │ ┌─── no merge conflicts
 │ │ │ ┌──── stack check
 │ │ │ │
"@
    }
    
    foreach ($pr in $sortedPRs) {
        $status = Get-PRStatusString $pr
        $prInfo = if ($Config.ShowPRLink) { $pr.url } else { "#$($pr.number)" }
        Write-Host "$status $prInfo : $($pr.title)"
    }
}

function Get-PRStatusString {
    param([object]$PR)
    
    $icons = if ($Config.StatusBitsEmojis) {
        @{ check = "✅"; cross = "❌"; pending = "⌛"; empty = "➖" }
    } else {
        @{ check = "v"; cross = "x"; pending = "."; empty = "-" }
    }
    
    $status = "["
    
    # Checks status (simplified - would need GraphQL API for full check status)
    if ($Config.RequireChecks) {
        # Try to get check status from gh pr view
        $prDetails = gh pr view $PR.number --json statusCheckRollup 2>$null | ConvertFrom-Json
        if ($prDetails.statusCheckRollup) {
            $allPass = $true
            foreach ($check in $prDetails.statusCheckRollup) {
                if ($check.state -ne "SUCCESS") {
                    $allPass = $false
                    break
                }
            }
            $status += if ($allPass) { $icons.check } else { $icons.cross }
        } else {
            $status += $icons.pending
        }
    } else {
        $status += $icons.empty
    }
    
    # Approval status
    if ($Config.RequireApproval) {
        $status += if ($PR.reviewDecision -eq "APPROVED") { $icons.check } else { $icons.cross }
    } else {
        $status += $icons.empty
    }
    
    # Merge conflicts
    $status += if ($PR.mergeable) { $icons.check } else { $icons.cross }
    
    # Stack status (simplified - would need to check all PRs below)
    $status += $icons.check  # Assume OK for now
    
    $status += "]"
    return $status
}

function Merge-PullRequests {
    $prs = Get-GitHubPRs
    $localCommits = Get-LocalCommitStack | Where-Object { -not $_.WIP }
    
    if ($prs.Count -eq 0) {
        Write-Host "No open pull requests." -ForegroundColor Yellow
        return
    }
    
    # Match PRs to commits and sort by commit order
    $prByCommitID = @{}
    foreach ($pr in $prs) {
        if ($pr.CommitID) {
            $prByCommitID[$pr.CommitID] = $pr
        }
    }
    
    $sortedPRs = @()
    foreach ($commit in $localCommits) {
        if ($prByCommitID.ContainsKey($commit.CommitID)) {
            $sortedPRs += $prByCommitID[$commit.CommitID]
        }
    }
    
    # Find top mergeable PR
    $prIndex = -1
    for ($i = 0; $i -lt $sortedPRs.Count; $i++) {
        $pr = $sortedPRs[$i]
        $prDetails = gh pr view $pr.number --json "mergeable,reviewDecision,statusCheckRollup" 2>$null | ConvertFrom-Json
        
        $isMergeable = $prDetails.mergeable -and
            ($prDetails.reviewDecision -eq "APPROVED" -or -not $Config.RequireApproval)
        
        if (-not $isMergeable) {
            $prIndex = $i - 1
            break
        }
        
        if ($Count -gt 0 -and ($i + 1) -eq $Count) {
            $prIndex = $i
            break
        }
    }
    
    if ($prIndex -eq -1) {
        if ($sortedPRs.Count -gt 0) {
            $prIndex = $sortedPRs.Count - 1
        } else {
            Write-Host "No mergeable pull requests." -ForegroundColor Yellow
            return
        }
    }
    
    $prToMerge = $sortedPRs[$prIndex]
    
    # Update base to target branch
    Write-Host "Updating PR #$($prToMerge.number) base to $($Config.GitHubBranch)..." -ForegroundColor Cyan
    gh pr edit $prToMerge.number --base $Config.GitHubBranch 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    
    # Merge the PR
    Write-Host "Merging PR #$($prToMerge.number)..." -ForegroundColor Cyan
    $mergeMethod = $Config.MergeMethod
    gh pr merge $prToMerge.number --$mergeMethod --delete-branch=false 2>&1 | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "MERGED #$($prToMerge.number) $($prToMerge.title)" -ForegroundColor Green
        
        # Close PRs below
        for ($i = 0; $i -lt $prIndex; $i++) {
            $pr = $sortedPRs[$i]
            $comment = "✓ Commit merged in pull request [#$($prToMerge.number)]($prToMerge.url)"
            gh pr comment $pr.number --body $comment 2>&1 | Out-Null
            gh pr close $pr.number 2>&1 | Out-Null
            Write-Host "MERGED #$($pr.number) $($pr.title)" -ForegroundColor Green
        }
    }
    
    # Show remaining PRs
    Show-PRStatus
}

function Sync-Stack {
    $prs = Get-GitHubPRs
    if ($prs.Count -eq 0) {
        Write-Host "No open pull requests." -ForegroundColor Yellow
        return
    }
    
    # Get the last PR's commit hash
    $lastPR = $prs[-1]
    $branchName = $lastPR.headRefName
    
    Write-Host "Syncing local stack with remote..." -ForegroundColor Cyan
    Invoke-GitCommand "cherry-pick ..$branchName" | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Stack synchronized" -ForegroundColor Green
    } else {
        Write-Host "Failed to sync stack" -ForegroundColor Red
    }
}

function Amend-Commit {
    # Check if there's already a rebase in progress
    $rebaseInProgress = (Test-Path .git/rebase-merge) -or (Test-Path .git/rebase-apply)
    if ($rebaseInProgress) {
        Write-Host "A rebase is already in progress. Aborting it first..." -ForegroundColor Yellow
        git rebase --abort 2>&1 | Out-Null
    }
    
    # Get commits without trying to add commit-ids (to avoid nested rebases)
    $remoteBranch = "$($Config.GitHubRemote)/$($Config.GitHubBranch)"
    $commitLog = ""
    if (-not (Invoke-GitCommand "log --format=medium --no-color $remoteBranch..HEAD" -Output "commitLog")) {
        Write-Host "No local commits found." -ForegroundColor Yellow
        return
    }
    
    $localCommits = Parse-CommitLog $commitLog
    # Generate temporary commit-ids if missing (we'll add real ones after amend)
    foreach ($commit in $localCommits) {
        if (-not $commit.CommitID) {
            $commit.CommitID = $commit.CommitHash.Substring(0, 8)
        }
    }
    
    if ($localCommits.Count -eq 0) {
        Write-Host "No commits to amend" -ForegroundColor Yellow
        return
    }
    
    # Display commits (newest first, numbered)
    Write-Host "`nCommits in stack:" -ForegroundColor Cyan
    for ($i = $localCommits.Count - 1; $i -ge 0; $i--) {
        $commit = $localCommits[$i]
        $commitID = if ($commit.CommitID) { $commit.CommitID.Substring(0, [Math]::Min(8, $commit.CommitID.Length)) } else { $commit.CommitHash.Substring(0, 8) }
        $number = $localCommits.Count - $i
        Write-Host " $number : $commitID : $($commit.Subject)" -ForegroundColor Gray
    }
    
    # Prompt for commit to amend
    if ($localCommits.Count -eq 1) {
        $prompt = "Commit to amend (1): "
    } else {
        $prompt = "Commit to amend (1-$($localCommits.Count)): "
    }
    
    $input = Read-Host $prompt
    $commitIndex = 0
    if (-not [int]::TryParse($input, [ref]$commitIndex)) {
        Write-Host "Invalid input" -ForegroundColor Red
        return
    }
    
    if ($commitIndex -lt 1 -or $commitIndex -gt $localCommits.Count) {
        Write-Host "Invalid commit number" -ForegroundColor Red
        return
    }
    
    # Convert to 0-based index (reverse order - newest is index 0)
    $targetIndex = $localCommits.Count - $commitIndex
    $targetCommit = $localCommits[$targetIndex]
    
    Write-Host "Amending commit: $($targetCommit.Subject)" -ForegroundColor Cyan
    
    # Check if there are staged changes
    $statusOutput = ""
    Invoke-GitCommand "status --porcelain --untracked-files=no" -Output "statusOutput" | Out-Null
    $hasStaged = ($statusOutput -split "`n" | Where-Object { $_ -match '^[AM]' }).Count -gt 0
    
    if (-not $hasStaged) {
        Write-Host "No staged changes. Stage your changes first with 'git add', then run amend again." -ForegroundColor Yellow
        return
    }
    
    # Create a fixup commit
    Write-Host "Creating fixup commit..." -ForegroundColor Cyan
    if (-not (Invoke-GitCommand "commit --fixup $($targetCommit.CommitHash)")) {
        Write-Host "Failed to create fixup commit" -ForegroundColor Red
        return
    }
    
    # Rebase with autosquash to automatically apply the fixup
    $remoteBranch = "$($Config.GitHubRemote)/$($Config.GitHubBranch)"
    Write-Host "Rebasing with autosquash to apply fixup..." -ForegroundColor Cyan
    
    # Use GIT_SEQUENCE_EDITOR to automatically accept the rebase todo without BOM
    $originalSeqEditor = $env:GIT_SEQUENCE_EDITOR
    $seqEditor = Join-Path $env:TEMP "git-spr-rebase-editor.ps1"
    $seqContent = @'
param($FilePath)
# Read the rebase todo, remove BOM, and write back without BOM
$content = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
# Remove BOM if present
$content = $content -replace '^\xEF\xBB\xBF', ''
# Write back without BOM
[System.IO.File]::WriteAllText($FilePath, $content, (New-Object System.Text.UTF8Encoding $false))
exit 0
'@
    $seqContent | Out-File -FilePath $seqEditor -Encoding utf8
    
    # Use GIT_EDITOR to automatically accept commit messages
    $originalEditor = $env:GIT_EDITOR
    $editor = Join-Path $env:TEMP "git-spr-commit-editor.ps1"
    $editorContent = @'
param($FilePath)
# Just accept the commit message as-is
exit 0
'@
    $editorContent | Out-File -FilePath $editor -Encoding utf8
    
    try {
        $env:GIT_SEQUENCE_EDITOR = "powershell -File `"$seqEditor`""
        $env:GIT_EDITOR = "powershell -File `"$editor`""
        
        # Run the rebase
        $rebaseOutput = ""
        Invoke-GitCommand "rebase -i --autosquash --autostash $remoteBranch" -Output "rebaseOutput" | Out-Null
        
        # Check if rebase is still in progress
        $rebaseInProgress = (Test-Path .git/rebase-merge) -or (Test-Path .git/rebase-apply)
        
        # Continue rebase until complete (may need multiple continues for reword operations)
        $maxContinues = 10
        $continueCount = 0
        while ($continueCount -lt $maxContinues) {
            $rebaseInProgress = (Test-Path .git/rebase-merge) -or (Test-Path .git/rebase-apply)
            if (-not $rebaseInProgress) {
                break
            }
            
            # Check if working tree is clean
            $statusOutput = ""
            Invoke-GitCommand "status --porcelain" -Output "statusOutput" | Out-Null
            if ($statusOutput.Trim() -eq "") {
                # Working tree is clean, continue the rebase
                Write-Host "Continuing rebase ($($continueCount + 1))..." -ForegroundColor Cyan
                if (-not (Invoke-GitCommand "rebase --continue")) {
                    # Check if it's just waiting for editor
                    $statusOutput2 = ""
                    Invoke-GitCommand "status" -Output "statusOutput2" | Out-Null
                    if ($statusOutput2 -match "all conflicts fixed") {
                        # Still in progress, try again
                        $continueCount++
                        continue
                    } else {
                        Write-Host "Rebase needs attention. Check status with 'git status' and continue with 'git rebase --continue'" -ForegroundColor Yellow
                        return
                    }
                }
                $continueCount++
            } else {
                Write-Host "Rebase in progress with uncommitted changes. Please resolve and run 'git rebase --continue'" -ForegroundColor Yellow
                return
            }
        }
        
        # Final check
        $rebaseInProgress = (Test-Path .git/rebase-merge) -or (Test-Path .git/rebase-apply)
        if (-not $rebaseInProgress) {
            Write-Host "✓ Commit amended successfully" -ForegroundColor Green
        } else {
            Write-Host "Rebase still in progress after $maxContinues attempts. Please check with 'git status' and continue manually with 'git rebase --continue'" -ForegroundColor Yellow
            return
        }
    } finally {
        # Restore original editors
        if ($originalSeqEditor) {
            $env:GIT_SEQUENCE_EDITOR = $originalSeqEditor
        } else {
            Remove-Item Env:\GIT_SEQUENCE_EDITOR -ErrorAction SilentlyContinue
        }
        if ($originalEditor) {
            $env:GIT_EDITOR = $originalEditor
        } else {
            Remove-Item Env:\GIT_EDITOR -ErrorAction SilentlyContinue
        }
        Remove-Item $seqEditor -ErrorAction SilentlyContinue
        Remove-Item $editor -ErrorAction SilentlyContinue
    }
    
    Write-Host "Run '.\git-spr.ps1 update' to update the pull request" -ForegroundColor Gray
}

# Main
Get-GitConfig

switch ($Command) {
    "update" {
        Update-PullRequests -Reviewers $Reviewer
    }
    "status" {
        Show-PRStatus
    }
    "merge" {
        Merge-PullRequests
    }
    "sync" {
        Sync-Stack
    }
    "amend" {
        Amend-Commit
    }
    "help" {
        Show-Help
    }
    default {
        Write-Host "Unknown command: $Command" -ForegroundColor Red
        Show-Help
        exit 1
    }
}

