#requires -Version 5.1
<#
.SYNOPSIS
Behavior tests for add-project-ci.ps1. All generated projects use the OS temp folder.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) { $PSNativeCommandUseErrorActionPreference = $false }
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$generator = Join-Path $repoRoot 'scripts\add-project-ci.ps1'
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$base = Join-Path $tempRoot ('github-project-ci-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($base)
$cases = [Collections.Generic.List[object]]::new()
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Check([string]$Name, [scriptblock]$Action) {
    try {
        & $Action
        $cases.Add([pscustomobject]@{Name=$Name; Passed=$true; Detail=''})
        Write-Host "PASS $Name"
    } catch {
        $cases.Add([pscustomobject]@{Name=$Name; Passed=$false; Detail=$_.Exception.Message})
        Write-Host "FAIL $Name : $($_.Exception.Message)"
    }
}
function Expect-Error([scriptblock]$Action, [string]$Pattern) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    Assert ($null -ne $caught) 'Expected refusal but the command succeeded.'
    Assert ($caught -match $Pattern) "Unexpected refusal: $caught"
}
function Text([string]$Path, [string]$Value) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Value.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
}
function New-Project([string]$Name) {
    $path = Join-Path $base $Name
    [void][IO.Directory]::CreateDirectory($path)
    return $path
}
function Workflow([string]$Project) { return Join-Path $Project '.github\workflows\project-checks.yml' }
function Read-Workflow([string]$Project) { return [IO.File]::ReadAllText((Workflow $Project), [Text.Encoding]::UTF8) }
function Run-Commands([string]$Project, [string]$Content) {
    $commands = @([regex]::Matches($Content, '(?m)^        run: \|\r?\n          (.+)$') | ForEach-Object {$_.Groups[1].Value.Trim()})
    Assert ($commands.Count -gt 0) 'No executable workflow checks were generated.'
    Push-Location -LiteralPath $Project
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        foreach ($command in $commands) {
            $global:LASTEXITCODE = 0
            $output = @(& ([scriptblock]::Create($command)) 2>&1)
            if ($LASTEXITCODE -ne 0) { throw "Generated command failed (exit $LASTEXITCODE): $command : $($output -join ' ')" }
        }
    } finally { $ErrorActionPreference = $savedPreference; Pop-Location }
}
function New-Node([string]$Name, [string]$Extra = '') {
    $path = New-Project $Name
    Text (Join-Path $path 'package.json') ('{"name":"ci-fixture","version":"1.0.0","private":true,"scripts":{"test":"node -e \"process.exit(0)\"","lint":"node -e \"process.exit(0)\"","build":"node -e \"process.exit(0)\""}' + $Extra + '}')
    Text (Join-Path $path 'package-lock.json') '{"name":"ci-fixture","version":"1.0.0","lockfileVersion":3,"requires":true,"packages":{"":{"name":"ci-fixture","version":"1.0.0"}}}'
    return $path
}
try {
    Check 'generator parses in this PowerShell host' {
        $tokens = $null; $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($generator, [ref]$tokens, [ref]$errors)
        Assert (@($errors).Count -eq 0) ($errors -join '; ')
    }
    Check 'WhatIf reads project but creates no workflow directories' {
        $path = New-Project 'preview'
        Text (Join-Path $path 'src\main.py') 'print("preview")'
        $before = (Get-FileHash -LiteralPath (Join-Path $path 'src\main.py')).Hash
        $result = & $generator -ProjectPath $path -WhatIf
        Assert ($result.Status -eq 'Preview') 'WhatIf did not return a preview.'
        Assert (-not (Test-Path -LiteralPath (Join-Path $path '.github'))) 'WhatIf wrote a directory.'
        Assert ((Get-FileHash -LiteralPath (Join-Path $path 'src\main.py')).Hash -eq $before) 'WhatIf changed source.'
    }
    Check 'documentation-only project needs no CI' {
        $path = New-Project 'docs'
        Text (Join-Path $path 'README.md') '# Documentation'
        $result = & $generator -ProjectPath $path
        Assert ($result.Status -eq 'NotNeeded') 'Documentation was treated as code.'
        Assert (-not (Test-Path -LiteralPath (Join-Path $path '.github'))) 'Documentation-only CI created files.'
    }
    Check 'Python compile-only workflow executes and detects invalid source' {
        $unicodeName = 'python [' + [char]0x4e2d + [char]0x6587 + "] O'Brien"
        $path = New-Project $unicodeName
        Text (Join-Path $path 'src\main.py') 'print("ready")'
        Text (Join-Path $path '.python-version') '3.13'
        $before = (Get-FileHash -LiteralPath (Join-Path $path 'src\main.py')).Hash
        $result = & $generator -ProjectPath $path
        Assert ($result.Status -eq 'Created' -and $result.Preset -eq 'Python' -and $result.PythonCheck -eq 'CompileOnly') 'Wrong Python selection.'
        Assert (Test-Path -LiteralPath (Workflow $path) -PathType Leaf) 'Workflow file is missing.'
        $content = Read-Workflow $path
        Assert ($content -match 'no tests detected') 'Compile-only limitation is missing.'
        Assert ($content -match "python-version-file: '.python-version'") 'Existing Python version was not used.'
        Assert ((Get-FileHash -LiteralPath (Join-Path $path 'src\main.py')).Hash -eq $before) 'Generator changed Python source.'
        Run-Commands $path $content
        Text (Join-Path $path 'src\main.py') 'def broken('
        (Get-Item -LiteralPath (Join-Path $path 'src\main.py')).LastWriteTimeUtc = [DateTime]::UtcNow.AddSeconds(5)
        Expect-Error { Run-Commands $path $content } 'Generated command failed'
    }
    Check 'unittest workflow executes actual tests and observes failures' {
        $path = New-Project 'unittest'
        Text (Join-Path $path 'src\main.py') 'value = 1'
        Text (Join-Path $path 'tests\test_value.py') "import unittest`nclass ValueTest(unittest.TestCase):`n    def test_value(self):`n        self.assertEqual(1, 1)`n"
        $result = & $generator -ProjectPath $path -Preset Python -PythonVersion 3.12
        Assert ($result.PythonCheck -eq 'unittest') 'unittest was not selected.'
        $content = Read-Workflow $path
        Run-Commands $path $content
        Text (Join-Path $path 'tests\test_value.py') "import unittest`nclass ValueTest(unittest.TestCase):`n    def test_value(self):`n        self.assertEqual(1, 999)`n"
        Expect-Error { Run-Commands $path $content } 'Generated command failed'
    }
    Check 'declared pytest reuses requirements without editing dependencies' {
        $path = New-Project 'pytest'
        Text (Join-Path $path 'requirements.txt') "pytest==8.4.2`n"
        Text (Join-Path $path 'pyproject.toml') "[tool.pytest.ini_options]`ntestpaths = ['tests']`n"
        Text (Join-Path $path 'tests\test_value.py') 'def test_value(): assert 1 == 1'
        $before = (Get-FileHash -LiteralPath (Join-Path $path 'requirements.txt')).Hash
        $result = & $generator -ProjectPath $path
        Assert ($result.PythonCheck -eq 'pytest') 'Declared pytest was not selected.'
        Assert ((Read-Workflow $path) -match "python -m pip install -r 'requirements.txt'") 'Existing requirements were not installed.'
        Assert ((Read-Workflow $path) -match 'python -m pytest') 'Existing pytest was not selected.'
        Assert ((Get-FileHash -LiteralPath (Join-Path $path 'requirements.txt')).Hash -eq $before) 'Requirements were changed.'
    }
    Check 'unconfigured third-party tests stop instead of pretending to compile-test' {
        $path = New-Project 'unknown-tests'
        Text (Join-Path $path 'tests\test_value.py') 'def test_value(): assert 1 == 1'
        Expect-Error { & $generator -ProjectPath $path } 'Cannot infer'
        Assert (-not (Test-Path -LiteralPath (Join-Path $path '.github'))) 'Refused project created a workflow directory.'
    }
    Check 'pytest config without installed pytest stops before writing' {
        $path = New-Project 'pytest-no-install'
        Text (Join-Path $path 'pytest.ini') '[pytest]'
        Text (Join-Path $path 'main.py') 'print(1)'
        Expect-Error { & $generator -ProjectPath $path } 'pytest is not declared'
        Assert (-not (Test-Path -LiteralPath (Workflow $path))) 'Refused pytest project created a workflow.'
    }
    Check 'npm workflow executes lockfile install and all existing check scripts' {
        $path = New-Node 'node'
        Text (Join-Path $path '.nvmrc') '22'
        $packageBefore = (Get-FileHash -LiteralPath (Join-Path $path 'package.json')).Hash
        $lockBefore = (Get-FileHash -LiteralPath (Join-Path $path 'package-lock.json')).Hash
        $result = & $generator -ProjectPath $path
        Assert ($result.Preset -eq 'Node' -and $result.NodeScripts.Count -eq 3) 'Node scripts were not selected.'
        $content = Read-Workflow $path
        Assert ($content -match "node-version-file: '.nvmrc'") 'Node version file was not used.'
        $oldAudit = $env:npm_config_audit; $oldFund = $env:npm_config_fund
        try {
            $env:npm_config_audit = 'false'; $env:npm_config_fund = 'false'
            Run-Commands $path $content
        } finally { $env:npm_config_audit = $oldAudit; $env:npm_config_fund = $oldFund }
        Assert ((Get-FileHash -LiteralPath (Join-Path $path 'package.json')).Hash -eq $packageBefore) 'package.json was changed.'
        Assert ((Get-FileHash -LiteralPath (Join-Path $path 'package-lock.json')).Hash -eq $lockBefore) 'package-lock.json was changed.'
    }
    Check 'npm projects without existing check scripts need no CI' {
        $path = New-Project 'node-no-checks'
        Text (Join-Path $path 'package.json') '{"name":"ci-fixture","version":"1.0.0","scripts":{"start":"node main.js"}}'
        Text (Join-Path $path 'package-lock.json') '{"lockfileVersion":3,"packages":{}}'
        $result = & $generator -ProjectPath $path
        Assert ($result.Status -eq 'NotNeeded') 'A new test script was assumed.'
        Assert (-not (Test-Path -LiteralPath (Join-Path $path '.github'))) 'Uncheckable npm project wrote CI.'
    }
    Check 'missing npm lockfile is refused without creating one' {
        $path = New-Project 'missing-lock'
        Text (Join-Path $path 'package.json') '{"name":"ci-fixture","scripts":{"test":"node --version"}}'
        Expect-Error { & $generator -ProjectPath $path } 'package-lock.json'
        Assert (-not (Test-Path -LiteralPath (Join-Path $path 'package-lock.json'))) 'Generator created a lockfile.'
        Assert (-not (Test-Path -LiteralPath (Join-Path $path '.github'))) 'Missing-lock project wrote CI.'
    }
    Check 'yarn and pnpm projects are refused and original markers preserved' {
        foreach ($marker in @('yarn.lock', 'pnpm-lock.yaml')) {
            $path = New-Node ($marker.Replace('.', '-'))
            Text (Join-Path $path $marker) 'original lock content'
            $before = (Get-FileHash -LiteralPath (Join-Path $path $marker)).Hash
            Expect-Error { & $generator -ProjectPath $path } 'Unsupported package manager'
            Assert ((Get-FileHash -LiteralPath (Join-Path $path $marker)).Hash -eq $before) 'Non-npm lockfile was changed.'
            Assert (-not (Test-Path -LiteralPath (Join-Path $path '.github'))) 'Non-npm project wrote CI.'
        }
    }
    Check 'packageManager declaration rejects non-npm even with npm lockfile' {
        $path = New-Node 'declared-pnpm' ',"packageManager":"pnpm@10.0.0"'
        $before = (Get-FileHash -LiteralPath (Join-Path $path 'package.json')).Hash
        Expect-Error { & $generator -ProjectPath $path } 'Only npm'
        Assert ((Get-FileHash -LiteralPath (Join-Path $path 'package.json')).Hash -eq $before) 'Package manager declaration changed.'
        Assert (-not (Test-Path -LiteralPath (Workflow $path))) 'Unsupported package manager wrote CI.'
    }
    Check 'Mixed preset generates separate Python and npm jobs' {
        $path = New-Node 'mixed'
        Text (Join-Path $path 'src\main.py') 'print(1)'
        $result = & $generator -ProjectPath $path -PythonVersion 3.13 -NodeVersion 22
        Assert ($result.Preset -eq 'Mixed') 'Auto did not select Mixed.'
        $content = Read-Workflow $path
        Assert ($content -match '(?m)^  python:$' -and $content -match '(?m)^  node:$') 'Mixed jobs were not both generated.'
        Assert ($content -match "python-version: '3.13'" -and $content -match "node-version: '22'") 'Explicit versions were not used.'
    }
    Check 'existing project-checks file refuses overwrite byte for byte' {
        $path = New-Project 'existing'
        Text (Join-Path $path 'main.py') 'print(1)'
        Text (Workflow $path) "name: Original`n"
        $before = (Get-FileHash -LiteralPath (Workflow $path)).Hash
        Expect-Error { & $generator -ProjectPath $path } 'already exists'
        Expect-Error { & $generator -ProjectPath $path -WhatIf } 'already exists'
        Assert ((Get-FileHash -LiteralPath (Workflow $path)).Hash -eq $before) 'Existing workflow changed.'
    }
    Check 'other workflows remain unchanged when project-checks is added' {
        $path = New-Project 'other-workflow'
        Text (Join-Path $path 'main.py') 'print(1)'
        $other = Join-Path $path '.github\workflows\release.yml'
        Text $other "name: Keep this workflow`n"
        $before = (Get-FileHash -LiteralPath $other).Hash
        [void](& $generator -ProjectPath $path)
        Assert (Test-Path -LiteralPath (Workflow $path)) 'New workflow missing.'
        Assert ((Get-FileHash -LiteralPath $other).Hash -eq $before) 'Other workflow changed.'
    }
    Check 'PowerShell preset tests the portable repository paths under both shells' {
        $path = New-Project 'powershell'
        Text (Join-Path $path 'tests\test-workflow.ps1') '# fixture'
        Text (Join-Path $path 'tests\test-ci.ps1') '# fixture'
        $result = & $generator -ProjectPath $path -Preset PowerShell
        $content = Read-Workflow $path
        Assert ($result.Preset -eq 'PowerShell') 'PowerShell preset was not selected.'
        Assert ($content -match 'runs-on: windows-latest' -and $content -match 'shell: \[pwsh, powershell\]') 'Both Windows shells are not covered.'
        Assert ($content -match '\./tests/test-workflow.ps1' -and $content -match '\./tests/test-ci.ps1') 'Portable test paths are missing.'
        Run-Commands $path $content
    }
    Check 'generated workflow uses least-privilege triggers and fixed action commits' {
        $path = New-Node 'fixed-actions'
        Text (Join-Path $path 'main.py') 'print(1)'
        [void](& $generator -ProjectPath $path)
        $content = Read-Workflow $path
        Assert ($content -match '(?m)^  contents: read$') 'Read-only default permissions missing.'
        foreach ($trigger in @('push', 'pull_request', 'workflow_dispatch')) { Assert ($content -match "(?m)^  ${trigger}:$") "Missing trigger $trigger" }
        $uses = @([regex]::Matches($content, '(?m)^      - uses: (\S+)') | ForEach-Object {$_.Groups[1].Value})
        Assert ($uses.Count -eq 4) 'Unexpected Actions in Mixed workflow.'
        foreach ($action in $uses) { Assert ($action -match '^actions/(checkout|setup-python|setup-node)@[a-f0-9]{40}$') "Action is not fixed to an official commit: $action" }
        $bytes = [IO.File]::ReadAllBytes((Workflow $path))
        Assert (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'Workflow unexpectedly contains a UTF-8 BOM.'
        Assert ($content -notmatch "`r") 'Workflow is not normalized to LF.'
    }
    Check 'invalid paths and version injection refuse without writing' {
        Expect-Error { & $generator -ProjectPath (Join-Path $base 'missing') } 'existing local Windows'
        $path = New-Project 'bad-version'
        Text (Join-Path $path 'main.py') 'print(1)'
        Expect-Error { & $generator -ProjectPath $path -PythonVersion "3.13`npermissions: write-all" } 'pattern'
        Assert (-not (Test-Path -LiteralPath (Join-Path $path '.github'))) 'Invalid version wrote CI.'
    }
} finally {
    # Verify the exact owned temp path before recursive removal; never touch the repository.
    $resolvedBase = [IO.Path]::GetFullPath($base)
    if ($resolvedBase.StartsWith($tempRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolvedBase) -match '^github-project-ci-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolvedBase -Recurse -Force
    } else { throw "Refusing cleanup outside the owned temporary directory: $resolvedBase" }
}
$failed = @($cases | Where-Object {-not $_.Passed})
[pscustomobject]@{PowerShell=$PSVersionTable.PSVersion.ToString(); Total=$cases.Count; Passed=$cases.Count-$failed.Count; Failed=$failed.Count; Cases=$cases.ToArray()}
if ($failed.Count) { throw "$($failed.Count) CI behavior test(s) failed." }
