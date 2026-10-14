#requires -Version 5.1
<#
.SYNOPSIS
Inspect or publish a reviewed, fixed Git commit with preflight, locking and local reports.
.NOTES
No automatic staging/commit. -Inspect/-Plan/-Doctor/-WhatIf do not publish.
#>
[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Medium')]
param(
    [Parameter(Mandatory=$true)][string]$ProjectPath,
    [string]$Repository,
    [ValidateSet('Private','Public')][string]$Visibility='Private',
    [string]$Remote='origin',
    [string]$GhPath,
    [switch]$Inspect,[switch]$Doctor,[switch]$Plan,[switch]$Initialize,
    [switch]$BackupBeforePublish,[string]$BackupRoot,[string]$BackupScriptPath
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {$PSNativeCommandUseErrorActionPreference=$false}
. (Join-Path $PSScriptRoot 'workflow-common.ps1')
$selected=@(@($Doctor,$Plan,$Initialize) | Where-Object {$_}).Count
if ($selected -gt 1) {throw 'Choose one of Doctor, Plan or Initialize.'}
if ($selected) {
    $mode='Doctor';if ($Plan) {$mode='Plan'};if ($Initialize) {$mode='Initialize'}
    $forward=@{ProjectPath=$ProjectPath;Action=$mode}
    foreach ($key in @('Repository','Visibility','Remote','GhPath','BackupBeforePublish','BackupRoot','WhatIf','Confirm')) {
        if ($PSBoundParameters.ContainsKey($key)) {$forward[$key]=$PSBoundParameters[$key]}
    }
    & (Join-Path $PSScriptRoot 'project-workflow.ps1') @forward
    return
}
function Assert-EffectiveTarget {
    foreach ($push in @($false,$true)) {
        $arguments=@('-C',$path,'remote','get-url','--all')
        if ($push) {$arguments+='--push'}
        $arguments+=$Remote
        $values=@((Checked $git $arguments) -split '\r?\n')
        if ($values.Count -ne 1) {throw 'Multiple effective Git URLs are not supported.'}
        if ((Parse-GitHubUrl $values[0]) -ne $Repository) {throw 'Effective Git URL resolves to a different repository; inspect url.*.insteadOf/pushInsteadOf. No push was attempted.'}
    }
}
foreach ($variableName in @('GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_COMMON_DIR','GIT_OBJECT_DIRECTORY','GIT_ALTERNATE_OBJECT_DIRECTORIES')) {
    if ([Environment]::GetEnvironmentVariable($variableName)) {throw "Unset $variableName before publishing."}
}
if ($env:GH_HOST -and $env:GH_HOST -ne 'github.com') {throw 'This helper targets github.com; unset GH_HOST.'}
$path=Get-GPPath $ProjectPath
$config=Read-GPConfig $path
if (-not $PSBoundParameters.ContainsKey('Repository')) {$Repository=$config.repository}
if (-not $PSBoundParameters.ContainsKey('Remote')) {$Remote=$config.remote}
if (-not $PSBoundParameters.ContainsKey('Visibility')) {$Visibility=$config.visibility}
if (-not $PSBoundParameters.ContainsKey('BackupBeforePublish')) {$BackupBeforePublish=$config.backupBeforePublish}
if (-not $PSBoundParameters.ContainsKey('BackupRoot')) {$BackupRoot=$config.backupRoot}
if ($Remote -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {throw 'Invalid remote name.'}
if (Test-Path -LiteralPath $path -PathType Leaf) {throw 'ProjectPath is a file.'}
$git=Find-App 'git.exe'
if (-not $git) {throw 'Git is missing.'}
if (-not $GhPath) {$GhPath=Find-App 'gh.exe'}
if (-not $GhPath -and (Test-Path -LiteralPath 'D:\DevTools\bin\gh.exe')) {$GhPath='D:\DevTools\bin\gh.exe'}
if (-not $GhPath -or -not (Test-Path -LiteralPath $GhPath -PathType Leaf)) {throw 'GitHub CLI is missing.'}
$login=Checked $GhPath @('api','--hostname','github.com','user','--jq','.login')
if ($login -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}$') {throw 'Invalid GitHub login response.'}
$isGit=$false;$branch=$null;$commit=$null;$bound=$null
if (Test-Path -LiteralPath $path -PathType Container) {
    $top=Run $git @('-C',$path,'rev-parse','--show-toplevel')
    if ($top.Code -eq 0) {
        if (-not ([IO.Path]::GetFullPath($top.Output).TrimEnd('\')).Equals($path,[StringComparison]::OrdinalIgnoreCase)) {throw 'ProjectPath is inside a wider repository; choose its actual root and review publication scope.'}
        $isGit=$true
        $branch=Checked $git @('-C',$path,'branch','--show-current')
        $head=Run $git @('-C',$path,'rev-parse','--verify','HEAD')
        if ($head.Code -eq 0) {$commit=$head.Output}
        $remoteValue=Run $git @('-C',$path,'config','--get-all',"remote.$Remote.url")
        if ($remoteValue.Code -eq 0) {
            $urls=@($remoteValue.Output -split '\r?\n')
            if ($urls.Count -ne 1) {throw 'Remote has multiple fetch URLs; select a single publication target.'}
            $bound=Parse-GitHubUrl $urls[0]
            $pushValue=Run $git @('-C',$path,'config','--get-all',"remote.$Remote.pushurl")
            if ($pushValue.Code -eq 0) {
                $pushUrls=@($pushValue.Output -split '\r?\n')
                if ($pushUrls.Count -ne 1 -or (Parse-GitHubUrl $pushUrls[0]) -ne $bound) {throw 'Fetch and push targets differ; resolve the repository binding before publishing.'}
            }
        }
    }
}
if ($Repository) {
    if ($Repository -notmatch '/') {$Repository="$login/$Repository"}
    if ($bound -and $bound -ne $Repository) {throw 'Requested repository conflicts with the existing remote. Original remote was preserved.'}
} elseif ($bound) {$Repository=$bound}
else {throw 'Provide -Repository OWNER/REPO for an unbound project.'}
if ($Repository -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9][A-Za-z0-9._-]{0,99}$' -or $Repository.EndsWith('.git')) {throw 'Invalid repository name.'}
if ($isGit) {
    if ($bound) {Assert-EffectiveTarget}
    elseif ((Parse-GitHubUrl (Checked $git @('-C',$path,'ls-remote','--get-url',"https://github.com/$Repository.git"))) -ne $Repository) {throw 'Effective Git URL resolves to a different repository. No push was attempted.'}
}
$response=Run $GhPath @('api','--hostname','github.com',"repos/$Repository")
$exists=$response.Code -eq 0;$repo=$null
if ($exists) {
    $repo=$response.Output | ConvertFrom-Json
    if (-not $repo.permissions.push) {throw 'The authenticated account does not have push permission.'}
    $Repository=$repo.full_name
} elseif ($response.Output -notmatch '\(HTTP 404\)') {throw "Repository lookup failed: $($response.Output)"}
$url="https://github.com/$Repository"
$preview=[pscustomobject]@{ProjectPath=$path;Account=$login;Repository=$Repository;Exists=$exists;Branch=$branch;Commit=$commit;Url=$url;HasBoundRemote=[bool]$bound;ExpectedBranch=$config.branch;BackupBeforePublish=[bool]$BackupBeforePublish}
if ($Inspect) {return $preview}
if (-not $isGit -or -not $commit) {throw 'Create and review a local Git commit before publishing. This helper does not stage or commit.'}
if (-not $branch) {throw 'Detached HEAD: choose the intended branch before publishing.'}
if ($config.branch -and $config.branch -ne $branch) {throw 'Current branch differs from project configuration. Review and update the binding before publishing.'}
[void](Checked $git @('check-ref-format','--branch',$branch))
$preflight=Get-GPPreflight $path $git $commit $Remote $config
$action="Publish fixed commit $commit on $branch to $Repository"
if (-not $exists) {$action="Create $Visibility repository; "+$action}
if (-not $PSCmdlet.ShouldProcess($path,$action)) {return [pscustomobject]@{Plan=$preview;Preflight=$preflight}}
$report=[pscustomobject][ordered]@{
    StartedAt=[DateTimeOffset]::Now.ToString('o');FinishedAt=$null;Status='Running';Step='preflight'
    Repository=$Repository;Branch=$branch;Commit=$commit;Url=$url;Verified=$false;Created=$false
    Preflight=$preflight;Backup=$null;Error=$null;LocalHeadMoved=$false
}
$lock=$null;$oldPrompt=$env:GIT_TERMINAL_PROMPT;$env:GIT_TERMINAL_PROMPT='0'
try {
    if (-not $preflight.Passed) {throw ('Publication preflight blocked: '+(@($preflight.Issues|ForEach-Object {$_.Rule+': '+$_.Path}) -join '; '))}
    Assert-GPPinned $path $git $branch $commit
    if ($BackupBeforePublish) {
        $report.Step='backup'
        if (-not $BackupScriptPath) {$BackupScriptPath=Join-Path $PSScriptRoot 'backup-project.ps1'}
        if (-not (Test-Path -LiteralPath $BackupScriptPath -PathType Leaf)) {throw 'Backup script unavailable; disable optional backup or pass a trusted -BackupScriptPath.'}
        $backupParameters=@{ProjectPath=$path}
        if ($BackupRoot) {$backupParameters.BackupRoot=$BackupRoot}
        $report.Backup=& $BackupScriptPath @backupParameters
        if (-not $report.Backup -or -not $report.Backup.Archive) {throw 'Backup did not produce a verified archive.'}
    }
    $report.Step='acquire-lock';$lock=Enter-GPLock $path $git
    Assert-GPPinned $path $git $branch $commit
    $shellPath="'"+$GhPath.Replace('\','/').Replace("'", "'\''")+"'"
    $auth=@('-c','credential.https://github.com.helper=','-c',('credential.https://github.com.helper=!'+$shellPath+' auth git-credential'))
    $report.Step='history-check'
    if ($exists -and -not $bound) {
        $heads=Checked $git ($auth+@('-C',$path,'ls-remote','--heads',($url+'.git')))
        if ($heads) {
            [void](Checked $git ($auth+@('-C',$path,'fetch','--no-tags',($url+'.git'),"refs/heads/*:refs/remotes/$Remote/*")))
            $common=Run $git @('-C',$path,'merge-base','HEAD',"refs/remotes/$Remote/$($repo.default_branch)")
            if ($common.Code -ne 0) {throw 'Existing nonempty repository has unrelated history. Clone it and import reviewed task files; local files and remote history were preserved.'}
        }
    }
    $report.Step='bind-remote'
    if (-not $bound) {[void](Checked $git @('-C',$path,'remote','add',$Remote,($url+'.git')))}
    Assert-EffectiveTarget
    Assert-GPPinned $path $git $branch $commit
    $report.Step='create-repository'
    if (-not $exists) {
        [void](Checked $GhPath @('repo','create',$Repository,('--'+$Visibility.ToLowerInvariant())))
        $report.Created=$true
    }
    $report.Step='push-pinned-commit'
    Assert-GPPinned $path $git $branch $commit
    # Push the reviewed object ID, never a moving local branch name.
    [void](Checked $git ($auth+@('-C',$path,'push','--no-follow-tags','--recurse-submodules=no',$Remote,($commit+':refs/heads/'+$branch))))
    $report.Step='verify'
    $actual=Checked $git ($auth+@('-C',$path,'ls-remote','--exit-code',$Remote,"refs/heads/$branch"))
    if (($actual -split '\s+')[0] -ne $commit) {throw 'Remote branch does not match the pinned commit.'}
    [void](Checked $git @('-C',$path,'config','--local',"branch.$branch.remote",$Remote))
    [void](Checked $git @('-C',$path,'config','--local',"branch.$branch.merge","refs/heads/$branch"))
    $current=Checked $git @('-C',$path,'rev-parse','HEAD')
    $currentBranch=Checked $git @('-C',$path,'branch','--show-current')
    $report.LocalHeadMoved=($current -ne $commit -or $currentBranch -ne $branch)
    $report.Verified=$true;$report.Status='Published'
    if ($report.LocalHeadMoved) {$report.Status='PublishedPinnedCommitLocalAdvanced'}
    $report.FinishedAt=[DateTimeOffset]::Now.ToString('o')
    $reportPath=Save-GPReport $path $git $report
    $dirty=Checked $git @('-C',$path,'status','--porcelain')
    [pscustomobject]@{
        Repository=$Repository;Url=$url;Branch=$branch;Commit=$commit;CommitUrl="$url/commit/$commit"
        Created=$report.Created;Verified=$true;HasUncommittedChanges=[bool]$dirty
        LocalHeadMoved=$report.LocalHeadMoved;Report=$reportPath;Backup=$report.Backup
    }
} catch {
    $failure=$_
    $report.Status='Failed';$report.Error=$_.Exception.Message;$report.FinishedAt=[DateTimeOffset]::Now.ToString('o')
    # Only the lock owner may replace shared state. Unique failure reports remain available.
    if ($null -eq $lock -and $report.Step -ne 'acquire-lock') {
        try {$lock=Enter-GPLock $path $git} catch {}
    }
    try {$reportPath=Save-GPReport $path $git $report ($null -ne $lock);Write-Warning "Publication failed at $($report.Step). Local report: $reportPath"}
    catch {Write-Warning 'Unable to save local failure report.'}
    throw $failure
} finally {if ($null -ne $lock) {$lock.Dispose()};$env:GIT_TERMINAL_PROMPT=$oldPrompt}
