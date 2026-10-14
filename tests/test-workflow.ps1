#requires -Version 5.1
param([string]$Workspace = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {$PSNativeCommandUseErrorActionPreference=$false}
$publisher=Join-Path $Workspace 'scripts\publish-github.ps1'
$stub=$null
$base=Join-Path ([IO.Path]::GetTempPath()) ('github-project-tests-ps'+$PSVersionTable.PSVersion.Major+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($base)
$stub=Join-Path $base 'gh stub.exe'
$tools=Join-Path $base 'tools'
[void][IO.Directory]::CreateDirectory($tools)
$realGit=(Get-Command git.exe -CommandType Application | Select-Object -First 1).Source
& powershell.exe -NoProfile -File (Join-Path $PSScriptRoot 'helpers\build-gh-stub.ps1') -Output $stub
if ($LASTEXITCODE -ne 0) {throw 'GH stub build failed'}
& powershell.exe -NoProfile -File (Join-Path $PSScriptRoot 'helpers\build-git-transport.ps1') -Output (Join-Path $tools 'git.exe')
if ($LASTEXITCODE -ne 0) {throw 'Git transport helper build failed'}
$results=[Collections.Generic.List[object]]::new()
function Assert($Condition,[string]$Message) {if (-not $Condition) {throw $Message}}
function Native([string]$File,[string[]]$Arguments) {
    $saved=$ErrorActionPreference;$ErrorActionPreference='Continue'
    try {$lines=@(& $File @Arguments 2>&1);$code=$LASTEXITCODE}
    finally {$ErrorActionPreference=$saved}
    if ($code -ne 0) {throw "$File exit $code : $($lines -join ' ')"}
    return ($lines -join [Environment]::NewLine).Trim()
}
function Text([string]$Path,[string]$Value) {[IO.File]::WriteAllText($Path,$Value,[Text.UTF8Encoding]::new($false))}
function Case([string]$Name,[scriptblock]$Body) {
    try {& $Body;$results.Add([pscustomobject]@{Name=$Name;Passed=$true;Detail=''});Write-Host "PASS $Name"}
    catch {$results.Add([pscustomobject]@{Name=$Name;Passed=$false;Detail=$_.Exception.Message});Write-Host "FAIL $Name : $($_.Exception.Message)"}
}
function Fails([scriptblock]$Body,[string]$Pattern) {
    $errorMessage=$null
    try {& $Body | Out-Null} catch {$errorMessage=$_.Exception.Message}
    Assert ($errorMessage -match $Pattern) "Expected $Pattern, received: $errorMessage"
}
function New-Fixture([string]$Name,[bool]$Exists=$false) {
    $directory=Join-Path $base $Name
    [void][IO.Directory]::CreateDirectory($directory)
    $source=Join-Path $directory "项目 [a] O'Brien"
    [void][IO.Directory]::CreateDirectory($source)
    [void](Native 'git.exe' @('-C',$source,'init','-b','main'))
    [void](Native 'git.exe' @('-C',$source,'config','user.name','Workflow Test'))
    [void](Native 'git.exe' @('-C',$source,'config','user.email','test@example.invalid'))
    Text (Join-Path $source 'source.txt') $Name
    [void](Native 'git.exe' @('-C',$source,'add','--','source.txt'))
    [void](Native 'git.exe' @('-C',$source,'commit','-m','Initial fixture'))
    $bare=Join-Path $directory 'remote.git'
    [void](Native 'git.exe' @('init','--bare','--initial-branch=main',$bare))
    $env:GH_TEST_STATE=Join-Path $directory 'state'
    $env:GH_TEST_LOG=Join-Path $directory 'create.log'
    if ($Exists) {Text $env:GH_TEST_STATE 'exists'}
    $env:GH_TEST_FAILURE=$null;$env:GH_TEST_DENY=$null
    $env:GIT_CONFIG_COUNT=$null; $env:GH_TEST_BARE=$bare
    $env:GIT_CONFIG_KEY_0=$null
    $env:GIT_CONFIG_VALUE_0=$null
    return [pscustomobject]@{Source=$source;Bare=$bare;Directory=$directory;State=$env:GH_TEST_STATE;Log=$env:GH_TEST_LOG}
}
$keys=@('GIT_CONFIG_COUNT','GIT_CONFIG_KEY_0','GIT_CONFIG_VALUE_0','GH_TEST_STATE','GH_TEST_LOG','GH_TEST_FAILURE','GH_TEST_DENY','GIT_TERMINAL_PROMPT','PATH','GH_TEST_REAL_GIT','GH_TEST_BARE','GH_TEST_ADVANCE_SOURCE','GH_TEST_ADVANCE_MARKER')
$before=@{};foreach ($key in $keys) {$before[$key]=[Environment]::GetEnvironmentVariable($key)}
try {
    $env:GH_TEST_REAL_GIT=$realGit
    $env:PATH=$tools+';'+$env:PATH
    Case 'parse publisher in current host' {
        $tokens=$null;$errors=$null
        [void][Management.Automation.Language.Parser]::ParseFile($publisher,[ref]$tokens,[ref]$errors)
        Assert (@($errors).Count -eq 0) ($errors -join '; ')
    }
    $fixture=New-Fixture 'main'
    Case 'Inspect permits a future non-Git project and does not create it' {
        $future=Join-Path $base 'future'
        $plan=& $publisher -ProjectPath $future -Repository demo -GhPath $stub -Inspect
        Assert (-not $plan.Exists -and $plan.Repository -eq 'TestOwner/demo') 'Wrong inspect plan.'
        Assert (-not (Test-Path -LiteralPath $future)) 'Inspect created project.'
        Assert (-not (Test-Path -LiteralPath $fixture.Log)) 'Inspect created remote.'
    }
    Case 'publish without a reviewed local commit stops before remote creation' {
        Fails {& $publisher -ProjectPath (Join-Path $base 'missing') -Repository demo -GhPath $stub} 'local Git commit'
        Assert (-not (Test-Path -LiteralPath $fixture.Log)) 'Created remote before local commit.'
    }
    Case 'WhatIf creates neither remote nor origin' {
        & $publisher -ProjectPath $fixture.Source -Repository demo -GhPath $stub -WhatIf | Out-Null
        Assert (-not (Test-Path -LiteralPath $fixture.State)) 'WhatIf created remote.'
        Assert (-not (Native 'git.exe' @('-C',$fixture.Source,'remote'))) 'WhatIf added origin.'
    }
    Case 'new repository uses private default and real Git push to isolated bare remote' {
        $result=& $publisher -ProjectPath $fixture.Source -Repository demo -GhPath $stub
        Assert ($result.Created -and $result.Verified) 'New publication not verified.'
        Assert ((Get-Content -LiteralPath $fixture.Log -Raw -Encoding UTF8) -match '--private') 'Private flag missing.'
        $head=Native 'git.exe' @('-C',$fixture.Source,'rev-parse','HEAD')
        Assert ((Native 'git.exe' @('--git-dir',$fixture.Bare,'rev-parse','refs/heads/main')) -eq $head) 'Wrong remote HEAD.'
        Assert ((Native 'git.exe' @('-C',$fixture.Source,'rev-parse','--abbrev-ref','--symbolic-full-name','@{upstream}')) -eq 'origin/main') 'No upstream.'
    }
    Case 'existing repository update uses origin without creating a duplicate' {
        Text (Join-Path $fixture.Source 'source.txt') 'second commit'
        [void](Native 'git.exe' @('-C',$fixture.Source,'add','--','source.txt'))
        [void](Native 'git.exe' @('-C',$fixture.Source,'commit','-m','Update fixture'))
        $result=& $publisher -ProjectPath $fixture.Source -GhPath $stub
        Assert ($result.Verified -and -not $result.Created) 'Existing publication not verified.'
        Assert (@(Get-Content -LiteralPath $fixture.Log).Count -eq 1) 'Created duplicate repository.'
    }
    Case 'idempotent publication does not make empty commits' {
        $head=Native 'git.exe' @('-C',$fixture.Source,'rev-parse','HEAD')
        $result=& $publisher -ProjectPath $fixture.Source -GhPath $stub
        Assert ($result.Verified -and $result.Commit -eq $head) 'Idempotent publication changed commit.'
    }
    Case 'explicit target conflict preserves original origin' {
        Fails {& $publisher -ProjectPath $fixture.Source -Repository 'OtherOwner/wrong' -GhPath $stub} 'conflicts'
        Assert ((Native 'git.exe' @('-C',$fixture.Source,'config','--get','remote.origin.url')) -eq 'https://github.com/TestOwner/demo.git') 'Origin changed.'
    }
    Case 'separate push target is rejected' {
        [void](Native 'git.exe' @('-C',$fixture.Source,'config','remote.origin.pushurl','https://github.com/OtherOwner/wrong.git'))
        try {Fails {& $publisher -ProjectPath $fixture.Source -GhPath $stub} 'Fetch and push targets differ'}
        finally {[void](Native 'git.exe' @('-C',$fixture.Source,'config','--unset','remote.origin.pushurl'))}
    }
    Case 'wider repository is not published from an arbitrary subdirectory' {
        $sub=Join-Path $fixture.Source 'subdir';[void][IO.Directory]::CreateDirectory($sub)
        Fails {& $publisher -ProjectPath $sub -Repository demo -GhPath $stub} 'wider repository'
    }
    Case 'network failure is not mistaken for a missing repository' {
        $env:GH_TEST_FAILURE='1'
        try {Fails {& $publisher -ProjectPath $fixture.Source -GhPath $stub} 'lookup failed'}
        finally {$env:GH_TEST_FAILURE=$null}
        Assert (@(Get-Content -LiteralPath $fixture.Log).Count -eq 1) 'Network error created repo.'
    }
    Case 'missing push permission stops publication' {
        $env:GH_TEST_DENY='1'
        try {Fails {& $publisher -ProjectPath $fixture.Source -GhPath $stub} 'push permission'}
        finally {$env:GH_TEST_DENY=$null}
    }
    Case 'pushInsteadOf cannot redirect publication to another repository' {
        $key='url.https://github.com/OtherOwner/wrong.git.pushInsteadOf'
        [void](Native 'git.exe' @('-C',$fixture.Source,'config',$key,'https://github.com/TestOwner/demo.git'))
        try {Fails {& $publisher -ProjectPath $fixture.Source -GhPath $stub -Inspect} 'Effective Git URL'}
        finally {[void](Native 'git.exe' @('-C',$fixture.Source,'config','--unset-all',$key))}
    }
    Case 'insteadOf cannot redirect the effective fetch target' {
        $key='url.https://github.com/OtherOwner/wrong.git.insteadOf'
        [void](Native 'git.exe' @('-C',$fixture.Source,'config',$key,'https://github.com/TestOwner/demo.git'))
        try {Fails {& $publisher -ProjectPath $fixture.Source -GhPath $stub -Inspect} 'Effective Git URL'}
        finally {[void](Native 'git.exe' @('-C',$fixture.Source,'config','--unset-all',$key))}
    }
    Case 'staged and untracked local files are not committed or uploaded by publisher' {
        Text (Join-Path $fixture.Source 'user-staged.txt') 'user work'
        Text (Join-Path $fixture.Source 'untracked.txt') 'untracked work'
        [void](Native 'git.exe' @('-C',$fixture.Source,'add','--','user-staged.txt'))
        $status=Native 'git.exe' @('-C',$fixture.Source,'status','--porcelain')
        $head=Native 'git.exe' @('-C',$fixture.Source,'rev-parse','HEAD')
        $result=& $publisher -ProjectPath $fixture.Source -GhPath $stub
        Assert ($result.Verified -and $result.HasUncommittedChanges) 'Dirty state not reported.'
        Assert ((Native 'git.exe' @('-C',$fixture.Source,'status','--porcelain')) -eq $status) 'Index or working tree changed.'
        Assert ((Native 'git.exe' @('--git-dir',$fixture.Bare,'rev-parse','main')) -eq $head) 'Uncommitted files were pushed.'
    }
    Case 'non-fast-forward push preserves newer remote history' {
        $f=New-Fixture 'non-fast-forward'
        [void](& $publisher -ProjectPath $f.Source -Repository demo -GhPath $stub)
        $other=Join-Path $f.Directory 'other'
        [void](Native 'git.exe' @('clone',$f.Bare,$other))
        [void](Native 'git.exe' @('-C',$other,'config','user.name','Remote User'))
        [void](Native 'git.exe' @('-C',$other,'config','user.email','remote@example.invalid'))
        Text (Join-Path $other 'remote.txt') 'new remote change'
        [void](Native 'git.exe' @('-C',$other,'add','--','remote.txt'))
        [void](Native 'git.exe' @('-C',$other,'commit','-m','Remote advanced'))
        [void](Native 'git.exe' @('-C',$other,'push','origin','main'))
        $remoteHead=Native 'git.exe' @('--git-dir',$f.Bare,'rev-parse','main')
        Fails {& $publisher -ProjectPath $f.Source -GhPath $stub} 'failed'
        Assert ((Native 'git.exe' @('--git-dir',$f.Bare,'rev-parse','main')) -eq $remoteHead) 'Newer history overwritten.'
    }
    Case 'unbound unrelated history is rejected for nonempty remote' {
        $f=New-Fixture 'unrelated' $true
        $other=Join-Path $f.Directory 'independent';[void][IO.Directory]::CreateDirectory($other)
        [void](Native 'git.exe' @('-C',$other,'init','-b','main'))
        [void](Native 'git.exe' @('-C',$other,'config','user.name','Independent'))
        [void](Native 'git.exe' @('-C',$other,'config','user.email','other@example.invalid'))
        Text (Join-Path $other 'other.txt') 'independent root'
        [void](Native 'git.exe' @('-C',$other,'add','--','other.txt'))
        [void](Native 'git.exe' @('-C',$other,'commit','-m','Independent history'))
        [void](Native 'git.exe' @('-C',$other,'push',$f.Bare,'main'))
        $remoteHead=Native 'git.exe' @('--git-dir',$f.Bare,'rev-parse','main')
        Fails {& $publisher -ProjectPath $f.Source -Repository demo -GhPath $stub} 'unrelated history'
        Assert (-not (Native 'git.exe' @('-C',$f.Source,'remote'))) 'Wrong binding added.'
        Assert ((Native 'git.exe' @('--git-dir',$f.Bare,'rev-parse','main')) -eq $remoteHead) 'Independent remote overwritten.'
    }
    Case 'detached HEAD refuses publication' {
        $f=New-Fixture 'detached'
        [void](Native 'git.exe' @('-C',$f.Source,'checkout','--detach','HEAD'))
        Fails {& $publisher -ProjectPath $f.Source -Repository demo -GhPath $stub} 'Detached HEAD'
        Assert (-not (Test-Path -LiteralPath $f.State)) 'Detached HEAD created remote.'
    }
    Case 'Git redirection is refused' {
        $old=$env:GIT_DIR;$env:GIT_DIR=Join-Path $fixture.Source '.git'
        try {Fails {& $publisher -ProjectPath $fixture.Source -Repository demo -GhPath $stub} 'Unset GIT_DIR'}
        finally {$env:GIT_DIR=$old}
    }

    Case 'Initialize persists binding and preserves starting staged baseline' {
        $f=New-Fixture 'initialize'
        Text (Join-Path $f.Source 'original-user.txt') 'preexisting staged work'
        [void](Native 'git.exe' @('-C',$f.Source,'add','--','original-user.txt'))
        $beforeIndex=Native 'git.exe' @('-C',$f.Source,'diff','--cached','--raw','--abbrev=40')
        $manager=Join-Path $Workspace 'scripts\project-workflow.ps1'
        $initialized=& $manager -ProjectPath $f.Source -Action Initialize -Repository demo -GhPath $stub
        $config=Get-Content -LiteralPath $initialized.Configuration -Raw -Encoding UTF8 | ConvertFrom-Json
        $baseline=Get-Content -LiteralPath $initialized.Baseline -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert ($config.schemaVersion -eq 2 -and $config.repository -eq 'TestOwner/demo' -and $config.branch -eq 'main') 'Wrong binding.'
        Assert ($baseline.OriginalStagedRaw -eq $beforeIndex) 'Starting index baseline lost.'
        Assert ((Native 'git.exe' @('-C',$f.Source,'diff','--cached','--raw','--abbrev=40')) -eq $beforeIndex) 'Initialize altered index.'
        $hash=(Get-FileHash -LiteralPath $initialized.Baseline).Hash
        & $manager -ProjectPath $f.Source -Action Initialize -GhPath $stub | Out-Null
        Assert ((Get-FileHash -LiteralPath $initialized.Baseline).Hash -eq $hash) 'Continuation replaced initial baseline.'
        $doctor=& $manager -ProjectPath $f.Source -Action Doctor -GhPath $stub
        Assert $doctor.Healthy 'Configured project doctor failed.'
    }
    Case 'Plan and WhatIf show scope without writing config reports or remote' {
        $f=New-Fixture 'read-only'
        Text (Join-Path $f.Source '.env') 'LOCAL_ONLY=placeholder'
        Text (Join-Path $f.Source '.env.example') 'LOCAL_ONLY='
        $manager=Join-Path $Workspace 'scripts\project-workflow.ps1'
        $beforeStatus=Native 'git.exe' @('-C',$f.Source,'status','--porcelain')
        $plan=& $manager -ProjectPath $f.Source -Action Plan -Repository demo -GhPath $stub
        Assert $plan.ReadOnly 'Missing read-only marker.'
        Assert (@($plan.Files|Where-Object {$_.Path -eq '.env' -and -not $_.Included}).Count -eq 1) 'Secret path included.'
        Assert (@($plan.Files|Where-Object {$_.Path -eq '.env.example' -and $_.Included}).Count -eq 1) 'Template omitted.'
        & $manager -ProjectPath $f.Source -Action Initialize -Repository demo -GhPath $stub -WhatIf | Out-Null
        & $publisher -ProjectPath $f.Source -Repository demo -GhPath $stub -WhatIf | Out-Null
        Assert (-not (Test-Path -LiteralPath (Join-Path $f.Source '.github-project.json'))) 'Read-only operation wrote config.'
        Assert (-not (Test-Path -LiteralPath (Join-Path $f.Source '.git\github-project'))) 'Read-only operation wrote report.'
        Assert (-not (Test-Path -LiteralPath $f.State)) 'Read-only operation created remote.'
        Assert ((Native 'git.exe' @('-C',$f.Source,'status','--porcelain')) -eq $beforeStatus) 'Read-only operation changed files.'
    }
    Case 'invalid config is rejected before replacing valid project config' {
        $f=New-Fixture 'invalid-config'
        $manager=Join-Path $Workspace 'scripts\project-workflow.ps1'
        & $manager -ProjectPath $f.Source -Action Initialize -Repository demo -GhPath $stub | Out-Null
        $path=Join-Path $f.Source '.github-project.json';$hash=(Get-FileHash -LiteralPath $path).Hash
        Fails {& $manager -ProjectPath $f.Source -Action Initialize -Include '../*' -GhPath $stub} 'Invalid relative pattern'
        Assert ((Get-FileHash -LiteralPath $path).Hash -eq $hash) 'Invalid config replaced valid config.'
    }
    Case 'tracked sensitive filename blocks before repository creation and produces failure report' {
        $f=New-Fixture 'secret-path'
        Text (Join-Path $f.Source '.env') 'PLACEHOLDER=local'
        [void](Native 'git.exe' @('-C',$f.Source,'add','--','.env'))
        [void](Native 'git.exe' @('-C',$f.Source,'commit','-m','Unsafe fixture'))
        Fails {& $publisher -ProjectPath $f.Source -Repository demo -GhPath $stub} 'preflight blocked'
        Assert (-not (Test-Path -LiteralPath $f.State)) 'Blocked file created remote.'
        $state=Get-Content -LiteralPath (Join-Path $f.Source '.git\github-project\state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert ($state.status -eq 'Failed' -and $state.step -eq 'preflight') 'Failure state absent.'
    }
    Case 'token contents block and report contains no matched secret value' {
        $f=New-Fixture 'secret-content'
        $token='ghp_'+('a'*36)
        Text (Join-Path $f.Source 'source.txt') ('Example: '+$token)
        [void](Native 'git.exe' @('-C',$f.Source,'add','--','source.txt'))
        [void](Native 'git.exe' @('-C',$f.Source,'commit','-m','Unsafe text fixture'))
        Fails {& $publisher -ProjectPath $f.Source -Repository demo -GhPath $stub} 'github-token'
        $state=Get-Content -LiteralPath (Join-Path $f.Source '.git\github-project\state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $report=Get-Content -LiteralPath $state.lastReport -Raw -Encoding UTF8
        Assert (-not $report.Contains($token)) 'Report leaked matched token.'
        Assert (-not (Test-Path -LiteralPath $f.State)) 'Token was published.'
    }
    Case 'deleted secret in outgoing history still blocks publication' {
        $f=New-Fixture 'historic-secret'
        Text (Join-Path $f.Source 'old-secret.txt') ('ghp_'+('b'*36))
        [void](Native 'git.exe' @('-C',$f.Source,'add','--','old-secret.txt'))
        [void](Native 'git.exe' @('-C',$f.Source,'commit','-m','Unsafe historical fixture'))
        [void](Native 'git.exe' @('-C',$f.Source,'rm','--','old-secret.txt'))
        [void](Native 'git.exe' @('-C',$f.Source,'commit','-m','Delete fixture secret'))
        Fails {& $publisher -ProjectPath $f.Source -Repository demo -GhPath $stub} 'github-token'
        Assert (-not (Test-Path -LiteralPath $f.State)) 'Historical secret was published.'
    }
    Case 'configured file size ceiling blocks before remote mutation' {
        $f=New-Fixture 'large-file'
        [IO.File]::WriteAllBytes((Join-Path $f.Source 'large.bin'),[byte[]]::new(2MB))
        Text (Join-Path $f.Source '.github-project.json') '{"schemaVersion":2,"repository":"TestOwner/demo","maxFileMiB":1}'
        [void](Native 'git.exe' @('-C',$f.Source,'add','--','large.bin','.github-project.json'))
        [void](Native 'git.exe' @('-C',$f.Source,'commit','-m','Oversized fixture'))
        Fails {& $publisher -ProjectPath $f.Source -GhPath $stub} 'file-too-large'
        Assert (-not (Test-Path -LiteralPath $f.State)) 'Oversized blob created remote.'
    }
    Case 'repository guard serializes publishers without overwriting active state' {
        $f=New-Fixture 'lock'
        . (Join-Path $Workspace 'scripts\workflow-common.ps1')
        $guard=Enter-GPLock $f.Source $realGit
        try {
            Fails {& $publisher -ProjectPath $f.Source -Repository demo -GhPath $stub} 'repository lock'
            Assert (-not (Test-Path -LiteralPath $f.State)) 'Locked publisher created remote.'
            Assert (-not (Test-Path -LiteralPath (Join-Path $f.Source '.git\github-project\state.json'))) 'Competing publisher replaced active state.'
        } finally {$guard.Dispose()}
        $result=& $publisher -ProjectPath $f.Source -Repository demo -GhPath $stub
        Assert $result.Verified 'Guard remained locked after release.'
    }
    Case 'push pins reviewed SHA when another process advances local HEAD during push' {
        $f=New-Fixture 'concurrent-head'
        $pinned=Native 'git.exe' @('-C',$f.Source,'rev-parse','HEAD')
        $env:GH_TEST_ADVANCE_SOURCE=$f.Source
        $env:GH_TEST_ADVANCE_MARKER=Join-Path $f.Directory 'advance.once'
        try {$result=& $publisher -ProjectPath $f.Source -Repository demo -GhPath $stub}
        finally {$env:GH_TEST_ADVANCE_SOURCE=$null;$env:GH_TEST_ADVANCE_MARKER=$null}
        $now=Native 'git.exe' @('-C',$f.Source,'rev-parse','HEAD')
        Assert ($now -ne $pinned) 'Concurrency injection did not advance HEAD.'
        Assert ($result.Verified -and $result.LocalHeadMoved -and $result.Commit -eq $pinned) 'Concurrent change not accurately reported.'
        Assert ((Native 'git.exe' @('--git-dir',$f.Bare,'rev-parse','main')) -eq $pinned) 'Unreviewed advancing commit was pushed.'
    }
    Case 'optional bundled backup is verified and report records archive' {
        $f=New-Fixture 'backup'
        $result=& $publisher -ProjectPath $f.Source -Repository demo -GhPath $stub -BackupBeforePublish -BackupRoot (Join-Path $f.Directory 'backups')
        Assert ($result.Verified -and (Test-Path -LiteralPath $result.Backup.Archive)) 'Backup archive absent.'
        Assert ((Get-FileHash -LiteralPath $result.Backup.Archive -Algorithm SHA256).Hash.ToLowerInvariant() -eq $result.Backup.SHA256.ToLowerInvariant()) 'Backup hash mismatch.'
        $report=Get-Content -LiteralPath $result.Report -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert ($report.Backup.Archive -eq $result.Backup.Archive) 'Report missing backup.'
    }
    Case 'later preflight failure retains last successfully published commit' {
        $f=New-Fixture 'state-history'
        $success=& $publisher -ProjectPath $f.Source -Repository demo -GhPath $stub
        Text (Join-Path $f.Source '.env') 'BAD=placeholder'
        [void](Native 'git.exe' @('-C',$f.Source,'add','--','.env'))
        [void](Native 'git.exe' @('-C',$f.Source,'commit','-m','Unsafe followup fixture'))
        Fails {& $publisher -ProjectPath $f.Source -GhPath $stub} 'preflight blocked'
        $state=Get-Content -LiteralPath (Join-Path $f.Source '.git\github-project\state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert ($state.lastPublishedCommit -eq $success.Commit -and $state.lastAttemptCommit -ne $success.Commit -and $state.status -eq 'Failed') 'Last successful delivery was lost.'
    }


    Case 'stale tracking refs cannot hide deleted secret when remote is missing' {
        $f=New-Fixture 'stale-refs'
        Text (Join-Path $f.Source 'old-secret.txt') ('ghp_'+('c'*36))
        [void](Native 'git.exe' @('-C',$f.Source,'add','--','old-secret.txt'))
        [void](Native 'git.exe' @('-C',$f.Source,'commit','-m','Old unsafe fixture'))
        $old=Native 'git.exe' @('-C',$f.Source,'rev-parse','HEAD')
        [void](Native 'git.exe' @('-C',$f.Source,'update-ref','refs/remotes/origin/main',$old))
        [void](Native 'git.exe' @('-C',$f.Source,'rm','--','old-secret.txt'))
        [void](Native 'git.exe' @('-C',$f.Source,'commit','-m','Delete old unsafe fixture'))
        Fails {& $publisher -ProjectPath $f.Source -Repository demo -GhPath $stub} 'github-token'
        Assert (-not (Test-Path -LiteralPath $f.State)) 'Stale refs hid secret from new remote.'
    }
    Case 'followTags setting cannot publish additional annotated tags' {
        $f=New-Fixture 'tag-scope'
        [void](Native 'git.exe' @('-C',$f.Source,'tag','-a','local-only','-m','Local annotation'))
        [void](Native 'git.exe' @('-C',$f.Source,'config','push.followTags','true'))
        $result=& $publisher -ProjectPath $f.Source -Repository demo -GhPath $stub
        Assert $result.Verified 'Selected branch was not published.'
        Assert (-not (Native 'git.exe' @('--git-dir',$f.Bare,'for-each-ref','--format=%(refname)','refs/tags'))) 'Unselected tag was published.'
    }
    Case 'preflight failure while another publisher holds guard cannot replace shared state' {
        $f=New-Fixture 'lock-preflight'
        Text (Join-Path $f.Source '.env') 'PLACEHOLDER=unsafe'
        [void](Native 'git.exe' @('-C',$f.Source,'add','--','.env'))
        [void](Native 'git.exe' @('-C',$f.Source,'commit','-m','Unsafe lock fixture'))
        . (Join-Path $Workspace 'scripts\workflow-common.ps1')
        $guard=Enter-GPLock $f.Source $realGit
        try {
            Fails {& $publisher -ProjectPath $f.Source -Repository demo -GhPath $stub} 'preflight blocked'
            Assert (-not (Test-Path -LiteralPath (Join-Path $f.Source '.git\github-project\state.json'))) 'Failure without lock replaced shared state.'
            Assert (@(Get-ChildItem -LiteralPath (Join-Path $f.Source '.git\github-project\reports') -Filter '*.json').Count -eq 1) 'Unique failure report absent.'
        } finally {$guard.Dispose()}
    }

} finally {foreach ($key in $keys) {[Environment]::SetEnvironmentVariable($key,$before[$key])}}
$failed=@($results|Where-Object {-not $_.Passed}).Count
$report=[ordered]@{PowerShell=$PSVersionTable.PSVersion.ToString();Total=$results.Count;Passed=$results.Count-$failed;Failed=$failed;Backend='Stub GitHub metadata and real local bare Git transport; no network mutations';Cases=$results.ToArray()}
$reportPath=Join-Path $base 'results.json'
[IO.File]::WriteAllText($reportPath,($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
Write-Host "RESULT $($results.Count-$failed)/$($results.Count); $reportPath"
if ($failed) {exit 1}
exit 0
