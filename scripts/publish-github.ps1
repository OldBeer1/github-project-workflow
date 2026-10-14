#requires -Version 5.1
<#
.SYNOPSIS
Publish committed HEAD to GitHub, creating a missing private repository.
.NOTES
Does not stage or commit. -Inspect and -WhatIf do not mutate local/remote repositories.
#>
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
param(
    [Parameter(Mandatory=$true)][string]$ProjectPath,
    [string]$Repository,
    [ValidateSet('Private','Public')][string]$Visibility='Private',
    [string]$Remote='origin',
    [string]$GhPath,
    [switch]$Inspect
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {$PSNativeCommandUseErrorActionPreference=$false}
function Run([string]$File,[string[]]$Arguments) {
    $saved=$ErrorActionPreference
    $ErrorActionPreference='Continue'
    try {$lines=@(& $File @Arguments 2>&1);$code=$LASTEXITCODE}
    finally {$ErrorActionPreference=$saved}
    return [pscustomobject]@{Code=$code;Output=($lines -join [Environment]::NewLine).Trim()}
}
function Checked([string]$File,[string[]]$Arguments) {
    $result=Run $File $Arguments
    if ($result.Code -ne 0) {throw "$File failed (exit $($result.Code)): $($result.Output)"}
    return $result.Output
}
function Find-App([string]$Name) {
    $found=Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $found) {return $found.Source}
    return $null
}
function Parse-GitHubUrl([string]$Url) {
    $value=$Url.TrimEnd('/')
    if ($value -match '^https://github\.com/([^/\s]+)/([^/\s]+)$' -or
        $value -match '^git@github\.com:([^/\s]+)/([^/\s]+)$' -or
        $value -match '^ssh://git@github\.com/([^/\s]+)/([^/\s]+)$') {
        return ($Matches[1]+'/'+($Matches[2] -replace '\.git$',''))
    }
    throw 'Remote must be a canonical github.com URL without embedded credentials.'
}
function Assert-EffectiveTarget {
    $prefix=@('-C',$path)
    foreach ($push in @($false,$true)) {
        $arguments=$prefix+@('remote','get-url','--all')
        if ($push) {$arguments+='--push'}
        $arguments+=$Remote
        $values=@((Checked $git $arguments) -split '\r?\n')
        if ($values.Count -ne 1) {throw 'Multiple effective Git URLs are not supported.'}
        $target=Parse-GitHubUrl $values[0]
        if ($target -ne $Repository) {throw 'Effective Git URL resolves to a different repository; inspect url.*.insteadOf/pushInsteadOf. No push was attempted.'}
    }
}
foreach ($variableName in @('GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_COMMON_DIR','GIT_OBJECT_DIRECTORY','GIT_ALTERNATE_OBJECT_DIRECTORIES')) {
    if ([Environment]::GetEnvironmentVariable($variableName)) {throw "Unset $variableName before publishing."}
}
if ($env:GH_HOST -and $env:GH_HOST -ne 'github.com') {throw 'This helper targets github.com; unset GH_HOST.'}
if ($Remote -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {throw 'Invalid remote name.'}
$path=[IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProjectPath)).TrimEnd('\')
if ($path -notmatch '^[A-Za-z]:\\') {throw 'Use a local Windows project path.'}
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
        $root=[IO.Path]::GetFullPath($top.Output).TrimEnd('\')
        if (-not $root.Equals($path,[StringComparison]::OrdinalIgnoreCase)) {throw 'ProjectPath is inside a wider repository; choose its actual root and review publication scope.'}
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
    else {
        $effective=Checked $git @('-C',$path,'ls-remote','--get-url',"https://github.com/$Repository.git")
        if ((Parse-GitHubUrl $effective) -ne $Repository) {throw 'Effective Git URL resolves to a different repository. No push was attempted.'}
    }
}
$response=Run $GhPath @('api','--hostname','github.com',"repos/$Repository")
$exists=$response.Code -eq 0
$repo=$null
if ($exists) {
    $repo=$response.Output | ConvertFrom-Json
    if (-not $repo.permissions.push) {throw 'The authenticated account does not have push permission.'}
    $Repository=$repo.full_name
} elseif ($response.Output -notmatch '\(HTTP 404\)') {throw "Repository lookup failed: $($response.Output)"}
$url="https://github.com/$Repository"
$plan=[pscustomobject]@{ProjectPath=$path;Account=$login;Repository=$Repository;Exists=$exists;Branch=$branch;Commit=$commit;Url=$url;HasBoundRemote=[bool]$bound}
if ($Inspect) {return $plan}
if (-not $isGit -or -not $commit) {throw 'Create and review a local Git commit before publishing. This helper does not stage or commit.'}
if (-not $branch) {throw 'Detached HEAD: choose the intended branch before publishing.'}
[void](Checked $git @('check-ref-format','--branch',$branch))
$action="Push committed $branch to $Repository"
if (-not $exists) {$action="Create $Visibility repository $Repository; "+$action}
if (-not $PSCmdlet.ShouldProcess($path,$action)) {return $plan}

$shellPath="'"+$GhPath.Replace('\','/').Replace("'", "'\''")+"'"
$helper='!'+$shellPath+' auth git-credential'
$auth=@('-c','credential.https://github.com.helper=','-c',"credential.https://github.com.helper=$helper")
$oldPrompt=$env:GIT_TERMINAL_PROMPT
$env:GIT_TERMINAL_PROMPT='0'
try {
    if ($exists -and -not $bound) {
        $heads=Checked $git ($auth+@('-C',$path,'ls-remote','--heads',($url+'.git')))
        if ($heads) {
            # Do not bind independent local history to a nonempty remote silently.
            [void](Checked $git ($auth+@('-C',$path,'fetch','--no-tags',($url+'.git'),"refs/heads/*:refs/remotes/$Remote/*")))
            $defaultRef="refs/remotes/$Remote/$($repo.default_branch)"
            $common=Run $git @('-C',$path,'merge-base','HEAD',$defaultRef)
            if ($common.Code -ne 0) {throw 'Existing nonempty repository has unrelated history. Clone it and import reviewed task files; local files and remote history were preserved.'}
        }
    }
    if (-not $bound) {[void](Checked $git @('-C',$path,'remote','add',$Remote,($url+'.git')))}
    # Check pushInsteadOf after binding, before any remote repository mutation.
    Assert-EffectiveTarget
    $created=$false
    if (-not $exists) {
        $flag='--'+$Visibility.ToLowerInvariant()
        [void](Checked $GhPath @('repo','create',$Repository,$flag))
        $created=$true
    }
    $refspec='refs/heads/'+$branch+':refs/heads/'+$branch
    [void](Checked $git ($auth+@('-C',$path,'push','--set-upstream',$Remote,$refspec)))
    $actual=Checked $git ($auth+@('-C',$path,'ls-remote','--exit-code',$Remote,"refs/heads/$branch"))
    if (($actual -split '\s+')[0] -ne $commit) {throw 'Remote branch does not match local HEAD.'}
    $dirty=Checked $git @('-C',$path,'status','--porcelain')
    [pscustomobject]@{Repository=$Repository;Url=$url;Branch=$branch;Commit=$commit;CommitUrl="$url/commit/$commit";Created=$created;Verified=$true;HasUncommittedChanges=[bool]$dirty}
} catch {
    Write-Warning "Local commits were preserved. Check $url before retrying; reuse any repository already created. No force push was attempted."
    throw
} finally {$env:GIT_TERMINAL_PROMPT=$oldPrompt}
