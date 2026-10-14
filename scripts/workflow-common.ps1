#requires -Version 5.1
# Shared local configuration, inspection and publication helpers.
function Find-App([string]$Name) {
    $found=Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $found) {return $found.Source}
    return $null
}
function Run([string]$File,[string[]]$Arguments,[string]$InputText) {
    $saved=$ErrorActionPreference
    $savedEncoding=[Console]::OutputEncoding
    $ErrorActionPreference='Continue'
    try {
        [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
        $OutputEncoding=[Text.UTF8Encoding]::new($false)
        if ($PSBoundParameters.ContainsKey('InputText')) {$lines=@($InputText | & $File @Arguments 2>&1)}
        else {$lines=@(& $File @Arguments 2>&1)}
        $code=$LASTEXITCODE
    } finally {$ErrorActionPreference=$saved;[Console]::OutputEncoding=$savedEncoding}
    return [pscustomobject]@{Code=$code;Output=($lines -join [Environment]::NewLine).Trim()}
}
function Checked([string]$File,[string[]]$Arguments,[string]$InputText) {
    if ($PSBoundParameters.ContainsKey('InputText')) {$result=Run $File $Arguments $InputText}
    else {$result=Run $File $Arguments}
    if ($result.Code -ne 0) {throw "$File failed (exit $($result.Code)): $($result.Output)"}
    return $result.Output
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
function Get-GPPath([string]$Value) {
    $full=[IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Value)).TrimEnd('\')
    if ($full -notmatch '^[A-Za-z]:\\') {throw 'Use a local Windows project directory, not an entire drive.'}
    return $full
}
function Get-GPDefaultConfig {
    return [pscustomobject][ordered]@{
        schemaVersion=2; repository=$null; remote='origin'; branch=$null; visibility='Private'
        include=@('*'); exclude=@('.github-project.local/*','work/*','*/work/*')
        maxFileMiB=100; maxTextScanMiB=1; backupBeforePublish=$false; backupRoot=$null
    }
}
function Read-GPConfig([string]$Root) {
    $config=Get-GPDefaultConfig
    $file=Join-Path $Root '.github-project.json'
    if (-not (Test-Path -LiteralPath $file)) {return $config}
    $raw=Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
    $allowed=@($config.PSObject.Properties.Name)
    foreach ($property in $raw.PSObject.Properties) {
        if ($property.Name -notin $allowed) {throw "Unknown configuration field: $($property.Name). Credentials and executable commands do not belong in this file."}
        $config.($property.Name)=$property.Value
    }
    Assert-GPConfig $config
    return $config
}
function Assert-GPConfig($Config) {
    if ($Config.schemaVersion -ne 2) {throw 'Unsupported workflow configuration schema.'}
    if ($Config.remote -isnot [string] -or $Config.remote -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {throw 'Invalid configured remote.'}
    if ($Config.visibility -notin @('Private','Public')) {throw 'Invalid configured visibility.'}
    foreach ($key in @('repository','branch','backupRoot')) {
        if ($null -ne $Config.$key -and $Config.$key -isnot [string]) {throw "$key must be a string or null."}
    }
    foreach ($key in @('include','exclude')) {
        if ($null -eq $Config.$key -or $Config.$key -isnot [Array]) {throw "$key must be an array of relative patterns."}
        foreach ($pattern in $Config.$key) {
            if ($pattern -isnot [string] -or -not $pattern -or $pattern.Contains(':') -or $pattern.StartsWith('/') -or $pattern.StartsWith('\') -or $pattern -match '(^|[/\\])\.\.([/\\]|$)') {throw "Invalid relative pattern in $key."}
        }
    }
    foreach ($key in @('maxFileMiB','maxTextScanMiB')) {
        if ($Config.$key -isnot [int] -and $Config.$key -isnot [long]) {throw "$key must be an integer."}
    }
    if ($Config.maxFileMiB -lt 1 -or $Config.maxFileMiB -gt 100) {throw 'maxFileMiB must be between 1 and 100.'}
    if ($Config.maxTextScanMiB -lt 1 -or $Config.maxTextScanMiB -gt 5) {throw 'maxTextScanMiB must be between 1 and 5.'}
    if ($Config.backupBeforePublish -isnot [bool]) {throw 'backupBeforePublish must be boolean.'}
}
function Write-GPJson([string]$Path,$Value) {
    $parent=[IO.Path]::GetDirectoryName($Path)
    [void][IO.Directory]::CreateDirectory($parent)
    if ((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Refusing to write through a linked workflow directory.'}
    if (Test-Path -LiteralPath $Path) {
        if ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Refusing to replace a linked workflow file.'}
    }
    $temporary=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($temporary,($Value|ConvertTo-Json -Depth 15),[Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $Path) {[IO.File]::Replace($temporary,$Path,[NullString]::Value)}
    else {[IO.File]::Move($temporary,$Path)}
}
function Get-GPLocalDirectory([string]$Root,[string]$Git) {
    if (Test-Path -LiteralPath $Root -PathType Container) {
        $directory=Run $Git @('-C',$Root,'rev-parse','--absolute-git-dir')
        if ($directory.Code -eq 0) {return Join-Path $directory.Output 'github-project'}
    }
    return Join-Path $Root '.github-project.local'
}
function Get-GPExcludedReason([string]$Relative,$Config) {
    $relative=$Relative.Replace('\','/')
    $leaf=($relative -split '/')[-1]
    if ($relative -match '(^|/)(\.git|\.github-project\.local|\.venv|node_modules|__pycache__|\.pytest_cache|\.mypy_cache|\.ruff_cache|\.tox|\.nox)(/|$)') {return 'environment/cache/internal metadata'}
    if (($leaf -eq '.env' -or $leaf -like '.env.*') -and $leaf -notin @('.env.example','.env.sample','.env.template')) {return 'potential secret filename'}
    if ($leaf -match '\.(pem|key|pfx|p12)$' -or $leaf -in @('id_rsa','id_ed25519','id_ecdsa','.npmrc','.pypirc','.netrc')) {return 'potential secret filename'}
    foreach ($pattern in $Config.exclude) {if ($relative -like $pattern) {return 'configured exclusion'}}
    $included=$false
    foreach ($pattern in $Config.include) {if ($relative -like $pattern) {$included=$true;break}}
    if (-not $included) {return 'outside configured include scope'}
    return $null
}
function Get-GPTextIssues([string]$Text,[string]$Path) {
    if ($Text.IndexOf([char]0) -ge 0) {return}
    $rules=[ordered]@{
        'private-key-header'='-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----'
        'github-token'='(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})'
        'aws-access-key'='(?:AKIA|ASIA)[A-Z0-9]{16}'
    }
    foreach ($name in $rules.Keys) {
        foreach ($match in [regex]::Matches($Text,$rules[$name])) {
            $line=1+[regex]::Matches($Text.Substring(0,$match.Index),'\n').Count
            [pscustomobject]@{Path=$Path;Rule=$name;Line=$line}
        }
    }
}
function Get-GPCandidates([string]$Root,[string]$Git,$Config) {
    $paths=@()
    $probe=Run $Git @('-C',$Root,'rev-parse','--show-toplevel')
    if ($probe.Code -eq 0) {
        $raw=Checked $Git @('-C',$Root,'-c','core.quotepath=false','ls-files','--cached','--others','--exclude-standard','-z')
        $paths=@($raw -split [char]0 | Where-Object {$_} | Sort-Object -Unique)
    } else {
        $pending=[Collections.Generic.Stack[string]]::new();$pending.Push($Root)
        $found=[Collections.Generic.List[string]]::new()
        while ($pending.Count) {
            foreach ($item in Get-ChildItem -LiteralPath $pending.Pop() -Force) {
                $relative=$item.FullName.Substring($Root.Length+1).Replace('\','/')
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {continue}
                if ($item.PSIsContainer) {
                    if ($item.Name -notin @('.git','.github-project.local','.venv','node_modules','__pycache__','work')) {$pending.Push($item.FullName)}
                } else {$found.Add($relative)}
            }
        }
        $paths=$found.ToArray()
    }
    foreach ($relative in $paths) {
        $file=Join-Path $Root $relative
        $reason=Get-GPExcludedReason $relative $Config
        $length=0;$deleted=-not (Test-Path -LiteralPath $file -PathType Leaf)
        if (-not $deleted) {$length=(Get-Item -LiteralPath $file -Force).Length}
        [pscustomobject]@{Path=$relative;Bytes=$length;Included=(-not [bool]$reason);Reason=$reason;Deleted=$deleted}
    }
}
function Get-GPPreflight([string]$Root,[string]$Git,[string]$Commit,[string]$Remote,$Config) {
    $issues=[Collections.Generic.List[object]]::new()
    $warnings=[Collections.Generic.List[string]]::new()
    $files=[Collections.Generic.List[object]]::new()
    $objects=@{}
    # The committed tree is authoritative; exclusions cannot silently remove tracked blobs.
    $tree=Checked $Git @('-C',$Root,'ls-tree','-r','-l','-z',$Commit)
    foreach ($entry in ($tree -split [char]0)) {
        if ($entry -match '^\d+\s+blob\s+([0-9a-f]+)\s+(\d+)\t(.+)$') {
            $oid=$Matches[1];$size=[long]$Matches[2];$relative=$Matches[3]
            $files.Add([pscustomobject]@{Path=$relative;Bytes=$size;Object=$oid})
            $objects[$oid]=[pscustomobject]@{Path=$relative;Bytes=$size}
            $reason=Get-GPExcludedReason $relative $Config
            if ($reason) {$issues.Add([pscustomobject]@{Path=$relative;Rule='tracked-excluded-path';Detail=$reason})}
        }
    }
    # Scan all reachable historical blobs; local tracking refs may be stale or refer to a deleted remote.
    $outgoing=Checked $Git @('-C',$Root,'rev-list','--objects',$Commit)
    $named=@{}
    foreach ($line in ($outgoing -split '\r?\n')) {
        if ($line -match '^([0-9a-f]{40,64}) (.+)$') {$named[$Matches[1]]=$Matches[2]}
    }
    if ($named.Count) {
        # Avoid stdin forwarding differences in Windows PowerShell hosts.
        # Read metadata only, then retain exactly the objects reachable from the pinned commit.
        $metadata=Checked $Git @('-C',$Root,'cat-file','--batch-all-objects','--batch-check=%(objectname) %(objecttype) %(objectsize)')
        $seen=@{}
        foreach ($line in ($metadata -split '\r?\n')) {
            if ($line -match '^([0-9a-f]+) (blob|tree|commit|tag) (\d+)$') {
                $oid=$Matches[1];$type=$Matches[2];$size=[long]$Matches[3]
                if (-not $named.ContainsKey($oid)) {continue}
                $seen[$oid]=$true
                if ($type -ne 'blob') {continue}
                if (-not $objects.ContainsKey($oid)) {$objects[$oid]=[pscustomobject]@{Path=$named[$oid];Bytes=$size}}
                $reason=Get-GPExcludedReason $named[$oid] $Config
                if ($reason) {$issues.Add([pscustomobject]@{Path=$named[$oid];Rule='outgoing-excluded-path';Detail=$reason})}
            }
        }
        if (@($named.Keys | Where-Object {-not $seen.ContainsKey($_)}).Count) {
            throw 'Incomplete Git object metadata; publication is blocked rather than skipping historical content.'
        }
    }
    foreach ($oid in $objects.Keys) {
        $item=$objects[$oid]
        if ($item.Bytes -gt ([long]$Config.maxFileMiB*1MB)) {$issues.Add([pscustomobject]@{Path=$item.Path;Rule='file-too-large';Detail='GitHub regular Git size limit exceeded'});continue}
        if ($item.Bytes -gt ([long]$Config.maxTextScanMiB*1MB)) {$warnings.Add("Content scan skipped above text scan limit: $($item.Path)");continue}
        $text=Checked $Git @('-C',$Root,'cat-file','blob',$oid)
        foreach ($issue in @(Get-GPTextIssues $text $item.Path)) {$issues.Add($issue)}
    }
    return [pscustomobject]@{
        Passed=($issues.Count -eq 0);Commit=$Commit
        Files=$files.ToArray();Issues=$issues.ToArray();Warnings=$warnings.ToArray()
        ObjectsChecked=$objects.Count;MaxTextScanMiB=$Config.maxTextScanMiB
    }
}
function Assert-GPPinned([string]$Root,[string]$Git,[string]$Branch,[string]$Commit) {
    $currentBranch=Checked $Git @('-C',$Root,'branch','--show-current')
    $head=Checked $Git @('-C',$Root,'rev-parse','HEAD')
    if ($currentBranch -ne $Branch -or $head -ne $Commit) {throw 'Local branch or HEAD changed after preflight. Review the new commit and retry; no unreviewed commit will be pushed.'}
}
function Enter-GPLock([string]$Root,[string]$Git) {
    $common=Checked $Git @('-C',$Root,'rev-parse','--git-common-dir')
    if (-not [IO.Path]::IsPathRooted($common)) {$common=[IO.Path]::GetFullPath((Join-Path $Root $common))}
    $lockPath=Join-Path $common 'github-project.publish.guard'
    if (Test-Path -LiteralPath $lockPath) {
        if ((Get-Item -LiteralPath $lockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Publication guard is a linked file.'}
    }
    try {
        $stream=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    } catch {throw 'Another publication holds this repository lock. Retry after it finishes.'}
    $bytes=[Text.Encoding]::UTF8.GetBytes(('pid='+$PID+';started='+[DateTimeOffset]::Now.ToString('o')))
    $stream.SetLength(0);$stream.Write($bytes,0,$bytes.Length);$stream.Flush()
    return $stream
}
function Save-GPReport([string]$Root,[string]$Git,$Report,[bool]$UpdateState=$true) {
    $directory=Get-GPLocalDirectory $Root $Git
    $stamp=[DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss-fff')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)
    $reportPath=Join-Path $directory ('reports\'+$stamp+'.json')
    Write-GPJson $reportPath $Report
    $markdown='# GitHub delivery'+[Environment]::NewLine+[Environment]::NewLine+
        'Status: '+$Report.Status+[Environment]::NewLine+'Repository: '+$Report.Repository+[Environment]::NewLine+
        'Branch: '+$Report.Branch+[Environment]::NewLine+'Commit: '+$Report.Commit+[Environment]::NewLine+
        'Verified: '+$Report.Verified+[Environment]::NewLine+'Step: '+$Report.Step+[Environment]::NewLine
    [IO.File]::WriteAllText([IO.Path]::ChangeExtension($reportPath,'.md'),$markdown,[Text.UTF8Encoding]::new($false))
    if ($UpdateState) {
        $statePath=Join-Path $directory 'state.json'
        $lastPublished=$null
        if (Test-Path -LiteralPath $statePath) {
            $oldState=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($oldState.PSObject.Properties['lastPublishedCommit']) {$lastPublished=$oldState.lastPublishedCommit}
        }
        if ($Report.Verified) {$lastPublished=$Report.Commit}
        Write-GPJson $statePath ([ordered]@{
            schemaVersion=2;updatedAt=[DateTimeOffset]::Now.ToString('o');repository=$Report.Repository
            branch=$Report.Branch;lastAttemptCommit=$Report.Commit;status=$Report.Status
            verified=$Report.Verified;lastPublishedCommit=$lastPublished;lastReport=$reportPath;step=$Report.Step
        })
    }
    return $reportPath
}
