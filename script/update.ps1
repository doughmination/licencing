# update.ps1
#
# Requires: git, and one of (gh CLI logged in) OR $env:GITHUB_TOKEN set.
# PowerShell 5.1 or 7+.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Config - edit these
# ---------------------------------------------------------------------------

$githubOwners = @(
    'doughmination'
    'clove-web'
    'clove-archives'
)

$licenceSource = '..\LICENCE.md'

$commitMessage = 'chore: update licence'

$excludeRepos = @(
    'nginx-config'
    'licencing'
    'tg'
    'sandrone-web'
    'email-server'
)

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tmpRoot | Out-Null

function Write-Info { param([string] $Message) Write-Host '[info] ' -ForegroundColor Blue   -NoNewline; Write-Host $Message }
function Write-Warn { param([string] $Message) Write-Host '[warn] ' -ForegroundColor Yellow -NoNewline; Write-Host $Message }
function Write-Fail { param([string] $Message) Write-Host '[fail] ' -ForegroundColor Red    -NoNewline; Write-Host $Message }

try {

    if (-not (Test-Path -LiteralPath $licenceSource -PathType Leaf)) {
        Write-Fail "licenceSource '$licenceSource' not found. Put your up-to-date licence text there first."
        exit 1
    }

    # -----------------------------------------------------------------------
    # Auth: prefer gh CLI, fall back to GITHUB_TOKEN
    # -----------------------------------------------------------------------

    $useGh = $false
    $hasGh = $null -ne (Get-Command gh -ErrorAction SilentlyContinue)

    if ($hasGh) {
        gh api user 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $useGh = $true
            $ghLogin = (gh api user --jq .login 2>$null)
            Write-Info "Using gh CLI for auth (account: $ghLogin)."
        }
    }

    if (-not $useGh) {
        if ($env:GITHUB_TOKEN) {
            Write-Info 'Using GITHUB_TOKEN for auth.'
        }
        else {
            Write-Fail "No auth available. Either log in with 'gh auth login', or set `$env:GITHUB_TOKEN = '<personal access token>'."
            if ($hasGh) {
                Write-Fail "(gh was found but 'gh api user' failed - the active gh account token may be invalid. Run 'gh auth status'.)"
            }
            else {
                Write-Fail '(gh was not found on PATH.)'
            }
            exit 1
        }
    }

    # -----------------------------------------------------------------------
    # Helpers
    # -----------------------------------------------------------------------

    function Test-Excluded {
        param(
            [string] $Owner,
            [string] $Repo
        )
        foreach ($excluded in $excludeRepos) {
            if ($excluded -eq $Repo) { return $true }
            if ($excluded -eq "$Owner/$Repo") { return $true }
        }
        return $false
    }

    function Get-CloneUrl {
        param(
            [string] $Owner,
            [string] $Repo
        )
        if ($useGh) {
            return "https://github.com/$Owner/$Repo.git"
        }
        return "https://x-access-token:$($env:GITHUB_TOKEN)@github.com/$Owner/$Repo.git"
    }

    # Skip LFS smudge on clone (matches the bash version)
    $env:GIT_LFS_SKIP_SMUDGE = '1'

    $updated   = @()
    $skipped   = @()
    $unchanged = @()
    $failed    = @()

    # -----------------------------------------------------------------------
    # Main loop
    # -----------------------------------------------------------------------

    foreach ($githubOwner in $githubOwners) {

        Write-Info "Fetching repo list for $githubOwner..."

        if ($useGh) {
            $repoListJson = (gh repo list $githubOwner --limit 200 --json name,defaultBranchRef,isArchived) -join "`n"

            # Assign first, THEN foreach. Piping ConvertFrom-Json straight into
            # ForEach-Object does not unroll the array on Windows PowerShell 5.1.
            $parsed = $repoListJson | ConvertFrom-Json
            $repoList = foreach ($item in $parsed) {
                [pscustomobject]@{
                    Name     = $item.name
                    Branch   = $item.defaultBranchRef.name
                    Archived = $item.isArchived
                }
            }
        }
        else {
            $headers = @{
                Authorization = "Bearer $($env:GITHUB_TOKEN)"
                Accept        = 'application/vnd.github+json'
            }
            $apiUrl = "https://api.github.com/users/$githubOwner/repos?per_page=200"
            $parsed = Invoke-RestMethod -Uri $apiUrl -Headers $headers
            $repoList = foreach ($item in $parsed) {
                [pscustomobject]@{
                    Name     = $item.name
                    Branch   = $item.default_branch
                    Archived = $item.archived
                }
            }
        }

        $activeRepos = $repoList | Where-Object { -not $_.Archived }

        foreach ($repo in $activeRepos) {
            $repoName = $repo.Name
            $branch   = $repo.Branch
            $label    = "$githubOwner/$repoName"

            if (Test-Excluded -Owner $githubOwner -Repo $repoName) {
                Write-Info "Skipping $repoName (excluded)."
                $skipped += $label
                continue
            }

            $dest = Join-Path $tmpRoot "$githubOwner-$repoName"

            Write-Info "Cloning $repoName (branch: $branch)..."

            if ($useGh) {
                gh repo clone "$githubOwner/$repoName" $dest -- --depth=1 --branch $branch -q 2>$null
            }
            else {
                git clone --depth=1 --branch $branch (Get-CloneUrl -Owner $githubOwner -Repo $repoName) $dest -q 2>$null
            }

            if ($LASTEXITCODE -ne 0) {
                Write-Warn "Clone failed for $repoName."
                $failed += $label
                continue
            }

            # Find an existing licence file (case-insensitive on Windows).
            $foundFile = Get-ChildItem -File -LiteralPath $dest |
                Where-Object { $_.Name -match '^licen[cs]e(\.(md|txt))?$' } |
                Select-Object -First 1

            if ($null -eq $foundFile) {
                $sourceExt = [System.IO.Path]::GetExtension($licenceSource)
                if ($sourceExt) {
                    $targetName = "LICENCE$sourceExt"
                }
                else {
                    $targetName = 'LICENCE'
                }
            }
            else {
                $foundName = $foundFile.Name

                # Rewrite American -> British, preserving case and extension.
                $targetName = $foundName -creplace 'NSE', 'NCE' -creplace 'nse', 'nce'

                if ($targetName -ne $foundName) {
                    Write-Info "  Renaming $foundName -> $targetName in $repoName"
                    git -C $dest mv $foundName $targetName
                }
            }

            Copy-Item -LiteralPath $licenceSource -Destination (Join-Path $dest $targetName) -Force

            Push-Location $dest
            try {
                $status = git status --porcelain -- $targetName

                if ([string]::IsNullOrWhiteSpace($status)) {
                    Write-Info "$repoName already up to date, nothing to commit."
                    $unchanged += $label
                    continue
                }

                git add $targetName
                git commit -m $commitMessage -q

                if (-not $useGh) {
                    git remote set-url origin (Get-CloneUrl -Owner $githubOwner -Repo $repoName)
                }

                git push origin "HEAD:$branch" -q 2>$null

                if ($LASTEXITCODE -eq 0) {
                    Write-Info "Pushed update to $repoName."
                    $updated += $label
                }
                else {
                    Write-Warn "Push failed for $repoName."
                    $failed += $label
                }
            }
            finally {
                Pop-Location
            }
        }
    }

    # -----------------------------------------------------------------------
    # Summary
    # -----------------------------------------------------------------------

    Write-Host ''
    Write-Info 'Done.'
    Write-Host "Updated:   $($updated.Count)  $($updated   -join ' ')"
    Write-Host "Unchanged: $($unchanged.Count)  $($unchanged -join ' ')"
    Write-Host "Skipped:   $($skipped.Count)  $($skipped   -join ' ')"
    Write-Host "Failed:    $($failed.Count)  $($failed    -join ' ')"
}
finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}
