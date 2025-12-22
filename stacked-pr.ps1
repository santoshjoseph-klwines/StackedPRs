# Stacked PR Helper Script
# Usage: .\stacked-pr.ps1 <command> [options]

param(
    [Parameter(Position = 0)]
    [ValidateSet("create", "rebase", "status", "list", "update", "update-from", "merge-stack", "help")]
    [string]$Command = "help",
    
    [Parameter(Position = 1)]
    [string]$BranchName = "",
    
    [Parameter(Position = 2)]
    [string]$BaseBranch = "",
    
    [string]$Title = "",
    [string]$Body = "",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Show-Help {
    Write-Host @"
Stacked PR Helper - Manage stacked pull requests with Git and GitHub CLI

USAGE:
    .\stacked-pr.ps1 <command> [options]

COMMANDS:
    create <branch-name> [base-branch]
        Create a new branch and PR. If base-branch is not specified, uses current branch.
        Example: .\stacked-pr.ps1 create feature-2 feature-1
        
    rebase <branch-name> [base-branch]
        Rebase a branch on top of another branch (or master if not specified).
        Example: .\stacked-pr.ps1 rebase feature-2 feature-1
        
    status
        Show status of all your open PRs and their relationships.
        
    list
        List all your open PRs.
        
    update <branch-name>
        Update a PR after rebasing (pushes with --force-with-lease).
        Example: .\stacked-pr.ps1 update feature-2
        
    update-from <branch-name>
        Automatically update all PRs stacked above the specified branch.
        Rebases all dependent PRs in the correct order (bottom to top).
        Example: .\stacked-pr.ps1 update-from feature-2
        
    merge-stack [base-branch]
        Merge all approved PRs in a stack into master (or specified base branch).
        Merges PRs in order from bottom to top. Only merges PRs that are approved and mergeable.
        Example: .\stacked-pr.ps1 merge-stack master
        
    help
        Show this help message.

OPTIONS:
    -Title "PR Title"      Set PR title (for create command)
    -Body "PR Description" Set PR body (for create command)
    -Force                 Use force push (use with caution)

EXAMPLES:
    # Create first feature branch and PR
    .\stacked-pr.ps1 create feature-1 master
    
    # Create second feature stacked on feature-1
    .\stacked-pr.ps1 create feature-2 feature-1
    
    # Rebase feature-2 when feature-1 changes
    .\stacked-pr.ps1 rebase feature-2 feature-1
    
    # Update all PRs above feature-2 (automatically handles feature-3, feature-4, etc.)
    .\stacked-pr.ps1 update-from feature-2
    
    # Merge all approved PRs in the stack into master
    .\stacked-pr.ps1 merge-stack master
    
    # Check status of all PRs
    .\stacked-pr.ps1 status
"@
}

function Get-CurrentBranch {
    $branch = git rev-parse --abbrev-ref HEAD
    if ($LASTEXITCODE -ne 0) {
        throw "Not in a git repository"
    }
    return $branch
}

function Get-PrInfo {
    param([string]$Branch)
    
    $prs = gh pr list --head $Branch --json "number,title,state,baseRefName,url" --limit 1
    if ($prs) {
        return $prs | ConvertFrom-Json | Select-Object -First 1
    }
    return $null
}

function New-StackedBranch {
    param(
        [string]$NewBranch,
        [string]$BaseBranch
    )
    
    Write-Host "Creating branch '$NewBranch' based on '$BaseBranch'..." -ForegroundColor Cyan
    
    # Check if branch already exists
    $branchExists = git show-ref --verify --quiet "refs/heads/$NewBranch"
    if ($branchExists -eq 0) {
        $response = Read-Host "Branch '$NewBranch' already exists. Checkout existing branch? (y/n)"
        if ($response -eq 'y') {
            git checkout $NewBranch
            return
        }
        else {
            throw "Branch '$NewBranch' already exists. Aborting."
        }
    }
    
    # Checkout base branch and ensure it's up to date
    Write-Host "Checking out base branch '$BaseBranch'..." -ForegroundColor Yellow
    git checkout $BaseBranch
    git pull origin $BaseBranch
    
    # Create new branch
    git checkout -b $NewBranch
    
    Write-Host "✓ Branch '$NewBranch' created based on '$BaseBranch'" -ForegroundColor Green
}

function New-StackedPr {
    param(
        [string]$Branch,
        [string]$BaseBranch,
        [string]$Title,
        [string]$Body
    )
    
    Write-Host "Creating PR for '$Branch' based on '$BaseBranch'..." -ForegroundColor Cyan
    
    # Check if PR already exists
    $existingPr = Get-PrInfo -Branch $Branch
    if ($existingPr) {
        Write-Host "PR already exists: $($existingPr.url)" -ForegroundColor Yellow
        return $existingPr
    }
    
    # Generate title if not provided
    if (-not $Title) {
        $Title = $Branch -replace '-', ' ' -replace '_', ' '
        $Title = (Get-Culture).TextInfo.ToTitleCase($Title.ToLower())
    }
    
    # Generate body if not provided
    if (-not $Body) {
        $Body = "Stacked PR: $Branch`n`nBased on: $BaseBranch"
    }
    
    # Ensure branch is pushed to remote (gh pr create requires the branch to exist on remote)
    Write-Host "Ensuring branch '$Branch' is pushed to remote..." -ForegroundColor Yellow
    $currentBranch = Get-CurrentBranch
    if ($currentBranch -ne $Branch) {
        git checkout $Branch
    }
    
    # Check if branch exists on remote
    git fetch origin $Branch 2>&1 | Out-Null
    $remoteExists = git ls-remote --heads origin $Branch
    if (-not $remoteExists) {
        Write-Host "Pushing branch '$Branch' to remote..." -ForegroundColor Yellow
        git push -u origin $Branch
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to push branch '$Branch' to remote"
        }
    }
    else {
        # Branch exists on remote, but make sure local is pushed
        git push origin $Branch 2>&1 | Out-Null
    }
    
    # Create PR (gh pr create doesn't support --json, so we create it and then fetch details)
    $prOutput = gh pr create --title $Title --body $Body --base $BaseBranch --head $Branch 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error creating PR:" -ForegroundColor Red
        Write-Host $prOutput -ForegroundColor Red
        throw "Failed to create PR: $prOutput"
    }
    
    # Wait a moment for GitHub to process the PR creation
    Start-Sleep -Seconds 1
    
    # Fetch PR details using gh pr view to get JSON output
    $prObj = Get-PrInfo -Branch $Branch
    if (-not $prObj) {
        # Fallback: try to parse URL from output if Get-PrInfo fails
        $urlMatch = [regex]::Match($prOutput, 'https://[^\s]+')
        if ($urlMatch.Success) {
            Write-Host "✓ PR created: $($urlMatch.Value)" -ForegroundColor Green
            # Return a basic object with the URL
            return [PSCustomObject]@{
                url    = $urlMatch.Value
                number = 0
                title  = $Title
            }
        }
        throw "PR was created but could not retrieve details"
    }
    
    Write-Host "✓ PR created: $($prObj.url)" -ForegroundColor Green
    return $prObj
}

function Update-StackedBranch {
    param(
        [string]$Branch,
        [string]$BaseBranch,
        [switch]$Force
    )
    
    Write-Host "Rebasing '$Branch' on top of '$BaseBranch'..." -ForegroundColor Cyan
    
    $currentBranch = Get-CurrentBranch
    
    # Ensure base branch is up to date
    Write-Host "Updating base branch '$BaseBranch'..." -ForegroundColor Yellow
    git fetch origin $BaseBranch
    
    # Checkout target branch
    if ($currentBranch -ne $Branch) {
        git checkout $Branch
    }
    
    # Rebase
    git rebase "origin/$BaseBranch"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Rebase had conflicts. Please resolve and run 'git rebase --continue'" -ForegroundColor Red
        throw "Rebase failed"
    }
    
    # Push
    if ($Force) {
        Write-Host "Force pushing..." -ForegroundColor Yellow
        git push --force origin $Branch
    }
    else {
        Write-Host "Pushing with --force-with-lease..." -ForegroundColor Yellow
        git push --force-with-lease origin $Branch
    }
    
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to push branch"
    }
    
    Write-Host "✓ Branch '$Branch' rebased and pushed" -ForegroundColor Green
    
    # Check if PR still exists after force push (GitHub sometimes closes PRs after force push)
    Start-Sleep -Seconds 1  # Give GitHub a moment to process
    $pr = Get-PrInfo -Branch $Branch
    if (-not $pr) {
        Write-Host "⚠ Warning: PR for branch '$Branch' was closed or doesn't exist after force push." -ForegroundColor Yellow
        Write-Host "  This can happen when branch history is rewritten. You may need to create a new PR." -ForegroundColor Yellow
    }
    elseif ($pr.state -ne "OPEN") {
        Write-Host "⚠ Warning: PR #$($pr.number) for branch '$Branch' is in state: $($pr.state)" -ForegroundColor Yellow
    }
}

function Show-PrStatus {
    Write-Host "Fetching PR status..." -ForegroundColor Cyan
    
    $prs = gh pr list --author "@me" --json "number,title,state,baseRefName,headRefName,url,isDraft" --limit 50
    if (-not $prs) {
        Write-Host "No open PRs found." -ForegroundColor Yellow
        return
    }
    
    $prList = $prs | ConvertFrom-Json | Where-Object { $_.state -eq "OPEN" }
    
    if ($prList.Count -eq 0) {
        Write-Host "No open PRs found." -ForegroundColor Yellow
        return
    }
    
    Write-Host "`nYour Open PRs:" -ForegroundColor Green
    Write-Host ("=" * 80)
    
    foreach ($pr in $prList) {
        $draft = if ($pr.isDraft) { " [DRAFT]" } else { "" }
        Write-Host "PR #$($pr.number): $($pr.title)$draft" -ForegroundColor Cyan
        Write-Host "  Branch: $($pr.headRefName) -> $($pr.baseRefName)" -ForegroundColor Gray
        Write-Host "  URL: $($pr.url)" -ForegroundColor Gray
        Write-Host ""
    }
    
    # Try to show relationships
    Write-Host "Branch Relationships:" -ForegroundColor Green
    Write-Host ("=" * 80)
    
    $baseBranches = $prList | Select-Object -ExpandProperty baseRefName -Unique
    foreach ($base in $baseBranches) {
        $stacked = $prList | Where-Object { $_.baseRefName -eq $base -and $_.headRefName -ne $base }
        if ($stacked.Count -gt 0) {
            Write-Host "$base" -ForegroundColor Yellow
            foreach ($pr in $stacked) {
                Write-Host "  └─ $($pr.headRefName) (PR #$($pr.number))" -ForegroundColor Gray
            }
        }
    }
}

function Show-PrList {
    gh pr list --author "@me" --limit 50
}

function Get-AllOpenPrs {
    $prs = gh pr list --author "@me" --json "number,title,state,baseRefName,headRefName,url,isDraft,mergeable,reviewDecision" --limit 50
    if (-not $prs) {
        return @()
    }
    $prList = $prs | ConvertFrom-Json | Where-Object { $_.state -eq "OPEN" }
    return $prList
}

function Get-PrDetails {
    param([int]$PrNumber)
    
    $pr = gh pr view $PrNumber --json "number,title,state,baseRefName,headRefName,url,isDraft,mergeable,reviewDecision,mergeStateStatus,reviews"
    if ($pr) {
        return $pr | ConvertFrom-Json
    }
    return $null
}

function Merge-Stack {
    param(
        [string]$BaseBranch = "master"
    )
    
    Write-Host "Finding all PRs in stack based on '$BaseBranch'..." -ForegroundColor Cyan
    
    # Get all open PRs
    $allPrs = Get-AllOpenPrs
    
    if ($allPrs.Count -eq 0) {
        Write-Host "No open PRs found." -ForegroundColor Yellow
        return
    }
    
    Write-Host "Found $($allPrs.Count) open PR(s):" -ForegroundColor Gray
    foreach ($pr in $allPrs) {
        Write-Host "  - PR #$($pr.number): $($pr.headRefName) -> $($pr.baseRefName)" -ForegroundColor Gray
    }
    
    # Build the stack: find all PRs that are part of the stack
    # Start with PRs that have BaseBranch as their base
    $script:stackPrs = [System.Collections.ArrayList]@()
    $script:processed = @{}
    
    function Find-StackPrs {
        param([string]$BranchName)
        
        if ($script:processed.ContainsKey($BranchName)) {
            return
        }
        $script:processed[$BranchName] = $true
        
        # Find PRs that have this branch as their base (use trimmed comparison)
        Write-Host "  Checking for PRs with baseRefName = '$BranchName'..." -ForegroundColor DarkGray
        $dependentPrs = $allPrs | Where-Object { 
            $baseRef = $_.baseRefName.ToString().Trim()
            $branch = $BranchName.ToString().Trim()
            $baseRef -eq $branch
        }
        Write-Host "  Found $($dependentPrs.Count) PR(s) with baseRefName = '$BranchName'" -ForegroundColor DarkGray
        
        foreach ($pr in $dependentPrs) {
            Write-Host "    - Found: PR #$($pr.number): $($pr.headRefName) -> $($pr.baseRefName)" -ForegroundColor DarkGray
            $exists = $script:stackPrs | Where-Object { $_.headRefName -eq $pr.headRefName }
            if ($exists.Count -eq 0) {
                [void]$script:stackPrs.Add($pr)
                Write-Host "      Added PR #$($pr.number) to stack (count now: $($script:stackPrs.Count))" -ForegroundColor DarkGray
            }
            # Recursively find PRs that depend on this PR
            Find-StackPrs -BranchName $pr.headRefName
        }
    }
    
    # Start from the base branch
    Find-StackPrs -BranchName $BaseBranch
    $stackPrs = @($script:stackPrs)
    
    if ($stackPrs.Count -eq 0) {
        Write-Host "No PRs found in stack based on '$BaseBranch'" -ForegroundColor Yellow
        return
    }
    
    # Sort PRs by dependency order (bottom to top)
    $script:sortedPrs = [System.Collections.ArrayList]@()
    $script:added = @{}
    
    function Add-PrInOrder {
        param([object]$Pr)
        
        if ($script:added.ContainsKey($Pr.headRefName)) {
            return
        }
        
        # If this PR's base is the BaseBranch, we can add it directly
        if ($Pr.baseRefName -eq $BaseBranch) {
            [void]$script:sortedPrs.Add($Pr)
            $script:added[$Pr.headRefName] = $true
            return
        }
        
        # Otherwise, first ensure the base PR (if it's in our list) is added first
        $basePr = $stackPrs | Where-Object { $_.headRefName -eq $Pr.baseRefName } | Select-Object -First 1
        if ($basePr) {
            Add-PrInOrder -Pr $basePr
        }
        
        # Then add this PR
        if (-not $script:added.ContainsKey($Pr.headRefName)) {
            [void]$script:sortedPrs.Add($Pr)
            $script:added[$Pr.headRefName] = $true
        }
    }
    
    foreach ($pr in $stackPrs) {
        Add-PrInOrder -Pr $pr
    }
    
    $sortedPrs = @($script:sortedPrs)
    
    Write-Host "`nFound $($sortedPrs.Count) PR(s) in stack:" -ForegroundColor Green
    foreach ($pr in $sortedPrs) {
        $status = "pending"
        $mergeable = "unknown"
        
        # Get detailed PR info to check approval status
        $prDetails = Get-PrDetails -PrNumber $pr.number
        if ($prDetails) {
            $mergeable = if ($prDetails.mergeable) { "yes" } else { "no" }
            $reviewDecision = $prDetails.reviewDecision
            if ($reviewDecision -eq "APPROVED") {
                $status = "approved"
            }
            elseif ($reviewDecision -eq "CHANGES_REQUESTED") {
                $status = "changes requested"
            }
            else {
                $status = "pending review"
            }
        }
        
        Write-Host "  - PR #$($pr.number): $($pr.title)" -ForegroundColor Cyan
        Write-Host "    Branch: $($pr.headRefName) -> $($pr.baseRefName)" -ForegroundColor Gray
        Write-Host "    Status: $status, Mergeable: $mergeable" -ForegroundColor $(if ($status -eq "approved" -and $mergeable -eq "yes") { "Green" } else { "Yellow" })
        Write-Host "    URL: $($pr.url)" -ForegroundColor Gray
        Write-Host ""
    }
    
    # Check if all PRs are approved and mergeable
    $allApproved = $true
    $allMergeable = $true
    
    foreach ($pr in $sortedPrs) {
        $prDetails = Get-PrDetails -PrNumber $pr.number
        if ($prDetails) {
            if ($prDetails.reviewDecision -ne "APPROVED") {
                $allApproved = $false
            }
            if (-not $prDetails.mergeable) {
                $allMergeable = $false
            }
        }
        else {
            $allApproved = $false
            $allMergeable = $false
        }
    }
    
    if (-not $allApproved) {
        Write-Host "⚠ Warning: Not all PRs are approved. Some PRs may not be ready to merge." -ForegroundColor Yellow
    }
    
    if (-not $allMergeable) {
        Write-Host "⚠ Warning: Not all PRs are mergeable. Please resolve conflicts or wait for CI checks." -ForegroundColor Yellow
    }
    
    if (-not $allApproved -or -not $allMergeable) {
        $response = Read-Host "`nSome PRs are not ready. Continue anyway? (y/n)"
        if ($response -ne 'y') {
            Write-Host "Aborted." -ForegroundColor Yellow
            return
        }
    }
    else {
        $response = Read-Host "`nAll PRs are approved and mergeable. Proceed with merging? (y/n)"
        if ($response -ne 'y') {
            Write-Host "Aborted." -ForegroundColor Yellow
            return
        }
    }
    
    # Merge each PR in order (bottom to top)
    # Each PR merges into its base branch, which gets updated as we merge
    foreach ($pr in $sortedPrs) {
        Write-Host "`n[$($sortedPrs.IndexOf($pr) + 1)/$($sortedPrs.Count)] Merging PR #$($pr.number): $($pr.title)..." -ForegroundColor Cyan
        Write-Host "  Merging $($pr.headRefName) into $($pr.baseRefName)..." -ForegroundColor Gray
        
        # Check if PR is still mergeable before merging
        $prDetails = Get-PrDetails -PrNumber $pr.number
        if ($prDetails -and -not $prDetails.mergeable) {
            Write-Host "⚠ PR #$($pr.number) is not mergeable. Skipping." -ForegroundColor Yellow
            Write-Host "  Please resolve conflicts or wait for CI checks, then run merge-stack again." -ForegroundColor Yellow
            continue
        }
        
        try {
            # For stacked PRs, we need to merge all PRs into the target BaseBranch (main/master),
            # not into their intermediate base branches. Change the PR's base to the target BaseBranch
            # before merging so all changes end up in the target branch.
            if ($pr.baseRefName -ne $BaseBranch) {
                Write-Host "  Changing PR base from '$($pr.baseRefName)' to '$BaseBranch'..." -ForegroundColor Yellow
                $changeBaseOutput = gh pr edit $pr.number --base $BaseBranch 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  ✓ PR base changed to '$BaseBranch'" -ForegroundColor Green
                    Start-Sleep -Seconds 3  # Wait for GitHub to update and check mergeability
                    
                    # Re-check if PR is still mergeable after base change
                    $prDetails = Get-PrDetails -PrNumber $pr.number
                    if ($prDetails -and -not $prDetails.mergeable) {
                        Write-Host "⚠ PR #$($pr.number) is not mergeable after base change. This may require manual resolution." -ForegroundColor Yellow
                        Write-Host "  You may need to rebase the branch onto $BaseBranch manually." -ForegroundColor Yellow
                        $response = Read-Host "Continue anyway? (y/n)"
                        if ($response -ne 'y') {
                            Write-Host "Skipping PR #$($pr.number)" -ForegroundColor Yellow
                            continue
                        }
                    }
                }
                else {
                    Write-Host "  ⚠ Could not change PR base: $changeBaseOutput" -ForegroundColor Yellow
                    Write-Host "  Will attempt to merge into original base '$($pr.baseRefName)'" -ForegroundColor Yellow
                    Write-Host "  Note: You may need to manually merge this branch into $BaseBranch later." -ForegroundColor Yellow
                }
            }
            
            # Determine the actual target base (may have been changed above)
            $actualBase = if ($pr.baseRefName -eq $BaseBranch -or $LASTEXITCODE -eq 0) { $BaseBranch } else { $pr.baseRefName }
            
            # Merge the PR using GitHub CLI (merge commit strategy, don't delete branch)
            Write-Host "  Merging PR #$($pr.number) into $actualBase..." -ForegroundColor Gray
            gh pr merge $pr.number --merge --delete-branch=false
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to merge PR #$($pr.number)"
            }
            
            Write-Host "✓ PR #$($pr.number) merged successfully into $actualBase" -ForegroundColor Green
            
            # Wait a moment for GitHub to process the merge and update dependent PRs
            Write-Host "  Waiting for GitHub to process merge..." -ForegroundColor Gray
            Start-Sleep -Seconds 3
            
            # Always fetch the target BaseBranch to update local refs
            Write-Host "  Updating local $BaseBranch branch..." -ForegroundColor Gray
            git fetch origin $BaseBranch
        }
        catch {
            Write-Host "✗ Failed to merge PR #$($pr.number)" -ForegroundColor Red
            Write-Host "  Error: $_" -ForegroundColor Red
            Write-Host "`nStopping merge process. Remaining PRs will need to be merged manually." -ForegroundColor Yellow
            Write-Host "  You can continue with: .\stacked-pr.ps1 merge-stack $BaseBranch" -ForegroundColor Yellow
            throw
        }
    }
    
    Write-Host "`n✓ All PRs in stack merged successfully!" -ForegroundColor Green
    Write-Host "  Stack merged into: $BaseBranch" -ForegroundColor Gray
}

function Update-FromBranch {
    param(
        [string]$BaseBranch,
        [switch]$Force
    )
    
    # Store the original branch to restore it at the end
    $originalBranch = Get-CurrentBranch
    
    Write-Host "Finding all PRs stacked above '$BaseBranch'..." -ForegroundColor Cyan
    
    # Get all open PRs
    $allPrs = Get-AllOpenPrs
    
    if ($allPrs.Count -eq 0) {
        Write-Host "No open PRs found." -ForegroundColor Yellow
        return
    }
    
    Write-Host "Found $($allPrs.Count) open PR(s):" -ForegroundColor Gray
    foreach ($pr in $allPrs) {
        Write-Host "  - PR #$($pr.number): $($pr.headRefName) -> $($pr.baseRefName)" -ForegroundColor Gray
    }
    
    # Build dependency graph: find all PRs that depend on BaseBranch (directly or indirectly)
    $script:prsToUpdate = [System.Collections.ArrayList]@()
    $script:processed = @{}
    
    function Find-DependentPrs {
        param([string]$BranchName)
        
        if ($script:processed.ContainsKey($BranchName)) {
            return
        }
        $script:processed[$BranchName] = $true
        
        # Find PRs that have this branch as their base
        Write-Host "  Checking for PRs with baseRefName = '$BranchName'..." -ForegroundColor DarkGray
        # Use explicit comparison with trimmed values to avoid whitespace issues
        $dependentPrs = $allPrs | Where-Object { 
            $baseRef = $_.baseRefName.ToString().Trim()
            $branch = $BranchName.ToString().Trim()
            $baseRef -eq $branch
        }
        Write-Host "  Found $($dependentPrs.Count) PR(s) with baseRefName = '$BranchName'" -ForegroundColor DarkGray
        
        foreach ($pr in $dependentPrs) {
            Write-Host "    - Found: PR #$($pr.number): $($pr.headRefName) -> $($pr.baseRefName)" -ForegroundColor DarkGray
            $exists = $script:prsToUpdate | Where-Object { $_.headRefName -eq $pr.headRefName }
            if ($exists.Count -eq 0) {
                [void]$script:prsToUpdate.Add($pr)
                Write-Host "      Added PR #$($pr.number) to update list (count now: $($script:prsToUpdate.Count))" -ForegroundColor DarkGray
            }
            else {
                Write-Host "      PR #$($pr.number) already in update list" -ForegroundColor DarkGray
            }
            # Recursively find PRs that depend on this PR
            Find-DependentPrs -BranchName $pr.headRefName
        }
    }
    
    # Start from the base branch
    Write-Host "`nSearching for PRs with baseRefName = '$BaseBranch'..." -ForegroundColor Gray
    Find-DependentPrs -BranchName $BaseBranch
    Write-Host "  script:prsToUpdate count: $($script:prsToUpdate.Count)" -ForegroundColor DarkGray
    # Convert ArrayList to regular array
    $prsToUpdate = @($script:prsToUpdate)
    Write-Host "  prsToUpdate count after assignment: $($prsToUpdate.Count)" -ForegroundColor DarkGray
    
    if ($prsToUpdate.Count -eq 0) {
        Write-Host "No PRs found stacked above '$BaseBranch'" -ForegroundColor Yellow
        $baseRefs = $allPrs | Select-Object -ExpandProperty baseRefName -Unique
        Write-Host "Available baseRefName values: $($baseRefs -join ', ')" -ForegroundColor Gray
        # No branches were switched, so we're still on the original branch
        return
    }
    
    # Sort PRs by dependency order (bottom to top) using topological sort
    # We need to process them in order: if PR-A depends on BaseBranch, and PR-B depends on PR-A,
    # we need to process PR-A before PR-B
    $script:sortedPrs = [System.Collections.ArrayList]@()
    $script:added = @{}
    
    function Add-PrInOrder {
        param([object]$Pr)
        
        if ($script:added.ContainsKey($Pr.headRefName)) {
            return
        }
        
        # If this PR's base is the BaseBranch, we can add it directly
        if ($Pr.baseRefName -eq $BaseBranch) {
            [void]$script:sortedPrs.Add($Pr)
            $script:added[$Pr.headRefName] = $true
            return
        }
        
        # Otherwise, first ensure the base PR (if it's in our list) is added first
        $basePr = $prsToUpdate | Where-Object { $_.headRefName -eq $Pr.baseRefName } | Select-Object -First 1
        if ($basePr) {
            Add-PrInOrder -Pr $basePr
        }
        
        # Then add this PR
        if (-not $script:added.ContainsKey($Pr.headRefName)) {
            [void]$script:sortedPrs.Add($Pr)
            $script:added[$Pr.headRefName] = $true
        }
    }
    
    foreach ($pr in $prsToUpdate) {
        Add-PrInOrder -Pr $pr
    }
    
    $sortedPrs = @($script:sortedPrs)
    Write-Host "`nFound $($sortedPrs.Count) PR(s) to update:" -ForegroundColor Green
    foreach ($pr in $sortedPrs) {
        Write-Host "  - $($pr.headRefName) (PR #$($pr.number)) based on $($pr.baseRefName)" -ForegroundColor Gray
    }
    Write-Host ""
    
    # Confirm before proceeding
    $response = Read-Host "Proceed with updating these PRs? (y/n)"
    if ($response -ne 'y') {
        Write-Host "Aborted." -ForegroundColor Yellow
        # Ensure we're still on the original branch (should already be, but just in case)
        $currentBranch = Get-CurrentBranch
        if ($currentBranch -ne $originalBranch) {
            git checkout $originalBranch 2>&1 | Out-Null
        }
        return
    }
    
    # Update each PR in order
    foreach ($pr in $sortedPrs) {
        Write-Host "`n[$($sortedPrs.IndexOf($pr) + 1)/$($sortedPrs.Count)] Updating $($pr.headRefName)..." -ForegroundColor Cyan
        try {
            Update-StackedBranch -Branch $pr.headRefName -BaseBranch $pr.baseRefName -Force:$Force
        }
        catch {
            Write-Host "Failed to update $($pr.headRefName). Stopping." -ForegroundColor Red
            Write-Host "Error: $_" -ForegroundColor Red
            # Restore original branch before throwing
            git checkout $originalBranch 2>&1 | Out-Null
            throw
        }
    }
    
    # Restore the original branch
    Write-Host "`nRestoring original branch '$originalBranch'..." -ForegroundColor Gray
    git checkout $originalBranch
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Warning: Could not restore branch '$originalBranch'" -ForegroundColor Yellow
    }
    
    Write-Host "`n✓ All PRs updated successfully!" -ForegroundColor Green
}

# Main command handler
switch ($Command) {
    "create" {
        if (-not $BranchName) {
            Write-Host "Error: Branch name required" -ForegroundColor Red
            Show-Help
            exit 1
        }
        
        if (-not $BaseBranch) {
            $BaseBranch = Get-CurrentBranch
            Write-Host "No base branch specified, using current branch: $BaseBranch" -ForegroundColor Yellow
        }
        
        New-StackedBranch -NewBranch $BranchName -BaseBranch $BaseBranch
        New-StackedPr -Branch $BranchName -BaseBranch $BaseBranch -Title $Title -Body $Body
    }
    
    "rebase" {
        if (-not $BranchName) {
            Write-Host "Error: Branch name required" -ForegroundColor Red
            Show-Help
            exit 1
        }
        
        if (-not $BaseBranch) {
            $BaseBranch = "master"
            Write-Host "No base branch specified, using: $BaseBranch" -ForegroundColor Yellow
        }
        
        Update-StackedBranch -Branch $BranchName -BaseBranch $BaseBranch -Force:$Force
    }
    
    "update" {
        if (-not $BranchName) {
            Write-Host "Error: Branch name required" -ForegroundColor Red
            Show-Help
            exit 1
        }
        
        $currentBranch = Get-CurrentBranch
        if ($currentBranch -ne $BranchName) {
            git checkout $BranchName
        }
        
        if ($Force) {
            git push --force origin $BranchName
        }
        else {
            git push --force-with-lease origin $BranchName
        }
        
        Write-Host "✓ Branch '$BranchName' pushed" -ForegroundColor Green
    }
    
    "update-from" {
        if (-not $BranchName) {
            Write-Host "Error: Branch name required" -ForegroundColor Red
            Show-Help
            exit 1
        }
        
        Update-FromBranch -BaseBranch $BranchName -Force:$Force
    }
    
    "merge-stack" {
        # For merge-stack, the base branch can be in $BranchName (position 1) or $BaseBranch (position 2)
        if (-not $BaseBranch -and $BranchName) {
            $BaseBranch = $BranchName
        }
        if (-not $BaseBranch) {
            $BaseBranch = "master"
            Write-Host "No base branch specified, using: $BaseBranch" -ForegroundColor Yellow
        }
        
        Merge-Stack -BaseBranch $BaseBranch
    }
    
    "status" {
        Show-PrStatus
    }
    
    "list" {
        Show-PrList
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

