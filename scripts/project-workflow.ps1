#requires -Version 5.1
<#
.SYNOPSIS
Initialize project bindings, inspect health or preview a GitHub delivery.
#>
[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Medium')]
param(
    [Parameter(Mandatory=$true)][string]$ProjectPath,
    [ValidateSet('Initialize','Doctor','Plan')][string]$Action='Doctor',
    [string]$Repository,[string]$Branch,[string]$Remote='origin',
    [ValidateSet('Private','Public')][string]$Visibility='Private',
    [string[]]$Include,[string[]]$Exclude,[switch]$BackupBeforePublish,
    [string]$BackupRoot,[string]$GhPath
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {$PSNativeCommandUseErrorActionPreference=$false}
. (Join-Path $PSScriptRoot 'workflow-common.ps1')
$root=Get-GPPath $ProjectPath
$git=Find-App 'git.exe'
$checks=[Collections.Generic.List[object]]::new()
$checks.Add([pscustomobject]@{Name='git';Passed=[bool]$git;Detail=$git})
$config=$null;$plan=$null
try {$config=Read-GPConfig $root;$checks.Add([pscustomobject]@{Name='configuration';Passed=$true;Detail='schema v2'})}
catch {$checks.Add([pscustomobject]@{Name='configuration';Passed=$false;Detail=$_.Exception.Message})}
$arguments=@{ProjectPath=$root;Inspect=$true}
foreach ($key in @('Repository','Remote','Visibility','GhPath')) {
    if ($PSBoundParameters.ContainsKey($key)) {$arguments[$key]=$PSBoundParameters[$key]}
}
try {$plan=& (Join-Path $PSScriptRoot 'publish-github.ps1') @arguments;$checks.Add([pscustomobject]@{Name='github-binding';Passed=$true;Detail=$plan.Repository})}
catch {$checks.Add([pscustomobject]@{Name='github-binding';Passed=$false;Detail=$_.Exception.Message})}
if ($Action -eq 'Doctor') {
    if ($config -and $config.backupBeforePublish) {$checks.Add([pscustomobject]@{Name='optional-backup';Passed=(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'backup-project.ps1'));Detail='bundled backup-project.ps1'})}
    if ($config -and $plan -and $config.branch) {$checks.Add([pscustomobject]@{Name='branch-binding';Passed=($config.branch -eq $plan.Branch);Detail=$plan.Branch})}
    $local=if ($git) {Get-GPLocalDirectory $root $git} else {$null}
    $lastState=$null
    if ($local -and (Test-Path -LiteralPath (Join-Path $local 'state.json'))) {$lastState=Get-Content -LiteralPath (Join-Path $local 'state.json') -Raw -Encoding UTF8|ConvertFrom-Json}
    return [pscustomobject]@{Healthy=(@($checks|Where-Object {-not $_.Passed}).Count -eq 0);Checks=$checks.ToArray();Plan=$plan;LastState=$lastState}
}
if ($null -eq $plan -or $null -eq $config -or -not $git) {throw ('Workflow setup check failed: '+(@($checks|Where-Object {-not $_.Passed}|ForEach-Object {$_.Detail}) -join '; '))}
if ($Action -eq 'Initialize') {
    if (-not $PSCmdlet.ShouldProcess($root,'Save project binding and starting Git baseline')) {return $plan}
    [void][IO.Directory]::CreateDirectory($root)
    $status='';$staged=''
    if ($plan.Branch) {
        $status=Checked $git @('-C',$root,'status','--porcelain')
        $staged=Checked $git @('-C',$root,'diff','--cached','--raw','--abbrev=40')
    }
    $config.repository=$plan.Repository
    $config.remote=if ($PSBoundParameters.ContainsKey('Remote')) {$Remote} else {$config.remote}
    $config.visibility=if ($PSBoundParameters.ContainsKey('Visibility')) {$Visibility} else {$config.visibility}
    if ($Branch) {$config.branch=$Branch}
    elseif ($plan.Branch) {$config.branch=$plan.Branch}
    elseif (-not $config.branch) {$config.branch='main'}
    if ($PSBoundParameters.ContainsKey('Include')) {$config.include=@($Include)}
    if ($PSBoundParameters.ContainsKey('Exclude')) {$config.exclude=@($Exclude)}
    if ($PSBoundParameters.ContainsKey('BackupBeforePublish')) {$config.backupBeforePublish=[bool]$BackupBeforePublish}
    if ($PSBoundParameters.ContainsKey('BackupRoot')) {$config.backupRoot=$BackupRoot}
    Assert-GPConfig $config
    Write-GPJson (Join-Path $root '.github-project.json') $config
    # Validate the exact saved configuration before using it for further operations.
    $config=Read-GPConfig $root
    $local=Get-GPLocalDirectory $root $git
    if ($local -eq (Join-Path $root '.github-project.local')) {
        $ignore=Join-Path $root '.gitignore'
        $ignoreText=if (Test-Path -LiteralPath $ignore) {[IO.File]::ReadAllText($ignore)} else {''}
        if ($ignoreText -notmatch '(?m)^\.github-project\.local/$') {
            [IO.File]::AppendAllText($ignore,[Environment]::NewLine+'.github-project.local/'+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
        }
    }

    $baseline=Join-Path $local 'baseline.json'
    # A continuation must retain the original baseline, not redefine user work as task work.
    if (-not (Test-Path -LiteralPath $baseline)) {
        Write-GPJson $baseline ([ordered]@{InitializedAt=[DateTimeOffset]::Now.ToString('o');Repository=$plan.Repository;Branch=$config.branch;Head=$plan.Commit;OriginalStatus=$status;OriginalStagedRaw=$staged})
    }
    return [pscustomobject]@{Configuration=(Join-Path $root '.github-project.json');Baseline=$baseline;Repository=$plan.Repository;Branch=$config.branch;BackupBeforePublish=$config.backupBeforePublish}
}
$manifest=@()
if (Test-Path -LiteralPath $root -PathType Container) {$manifest=@(Get-GPCandidates $root $git $config)}
$preflight=$null
if ($plan.Commit) {$preflight=Get-GPPreflight $root $git $plan.Commit $config.remote $config}
return [pscustomobject]@{Plan=$plan;Files=$manifest;Preflight=$preflight;ConfigurationExists=(Test-Path -LiteralPath (Join-Path $root '.github-project.json'));ReadOnly=$true}
