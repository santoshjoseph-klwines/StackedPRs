param(
    [Parameter(Mandatory=$true)]
    [string]$TargetCommit
)

$ErrorActionPreference = "Stop"

try {
    # 1. Stage all changes in the current directory and subdirectories
    Write-Host "Staging changes in $(Get-Location)..."
    git add .

    # 2. Check if there are actually staged changes to commit
    if (-not (git diff --cached --quiet)) {
        Write-Host "Creating fixup commit for $TargetCommit..."
        git commit --fixup=$TargetCommit
    } else {
        Write-Host "No staged changes to commit. Creating empty fixup? (Skipping for now)"
        # You might want to allow empty fixups if the intent is just to trigger a rebase, 
        # but usually we want to squash actual changes.
        # If there are no changes, maybe we just want to rebase?
        # Let's assume the user might have already committed a fixup manually? 
        # The prompt implies "add these changes", so we assume there ARE changes.
        # If no changes, we proceed to rebase just in case there are existing fixups?
        # Let's stick to the happy path: add changes -> commit -> rebase.
    }

    # 3. Perform the autosquash rebase
    Write-Host "Rebasing to squash into $TargetCommit..."
    
    # We need to set GIT_SEQUENCE_EDITOR to "true" (or a no-op command) so it doesn't open an interactive editor
    # and just accepts the autosquash plan.
    $env:GIT_SEQUENCE_EDITOR="true"
    
    # Target parent of the commit to ensure the commit itself can be modified
    git rebase -i --autosquash "${TargetCommit}~1"
    
    Write-Host "Success! Changes squashed into $TargetCommit." -ForegroundColor Green
}
catch {
    Write-Host "Error: $_" -ForegroundColor Red
    Write-Host "Rebase might be in progress or failed. Check 'git status'."
    exit 1
}
finally {
    # Cleanup environment variable
    $env:GIT_SEQUENCE_EDITOR=$null
}
