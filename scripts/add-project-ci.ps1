#requires -Version 5.1
<#
.SYNOPSIS
Add an optional GitHub Actions workflow using the project's existing checks.
.DESCRIPTION
Creates only .github/workflows/project-checks.yml and never overwrites it.
Auto recognizes Python source, npm projects, or this skill's PowerShell tests.
Python installs existing requirements.txt, requirements-dev.txt, requirements-test.txt,
and requirements/base.txt, requirements/dev.txt, requirements/test.txt when present.
pytest requires an existing declaration in those installed requirements; unittest
uses the standard library. No detected tests means an explicitly named compile check.
Node requires package-lock.json and uses only existing test/lint/build scripts.
No dependency or package-manager files are changed. No Git or GitHub writes occur.
.EXAMPLE
.\add-project-ci.ps1 -ProjectPath D:\Projects\demo -WhatIf
.EXAMPLE
.\add-project-ci.ps1 -ProjectPath D:\Projects\demo -Preset Mixed -PythonVersion 3.13 -NodeVersion 22
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)][string]$ProjectPath,
    [ValidateSet('Auto', 'Python', 'Node', 'Mixed', 'PowerShell')][string]$Preset = 'Auto',
    [ValidatePattern('^[0-9]+(?:\.[0-9x*]+){0,2}$')][string]$PythonVersion,
    [ValidatePattern('^(?:[0-9]+(?:\.[0-9x*]+){0,2}|lts/\*|node)$')][string]$NodeVersion
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
function Is-File([string]$Relative) { return Test-Path -LiteralPath (Join-Path $projectRoot $Relative) -PathType Leaf }
function Read-Text([string]$Relative) { return [IO.File]::ReadAllText((Join-Path $projectRoot $Relative), [Text.Encoding]::UTF8) }
function Assert-NoLink([string]$Path) {
    $cursor = $Path
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked paths are not supported: $cursor" }
            if (-not $item.PSIsContainer) { throw "Expected a directory: $cursor" }
        }
        $parent = [IO.Directory]::GetParent($cursor)
        if ($null -eq $parent) { break }
        $cursor = $parent.FullName
    }
}
function Quote-PS([string]$Value) { return "'" + $Value.Replace("'", "''") + "'" }
function Add-Line([string]$Value) { [void]$lines.Add($Value) }
function Add-Run([string]$Name, [string]$Command) {
    Add-Line "      - name: $Name"
    Add-Line '        run: |'
    Add-Line ('          ' + $Command)
}
function Add-Version([string]$Explicit, [string[]]$Candidates, [string]$Default, [string]$InputName) {
    Add-Line '        with:'
    if ($Explicit) { Add-Line ("          ${InputName}: '" + $Explicit + "'"); return }
    foreach ($candidate in $Candidates) {
        if (Is-File $candidate) {
            Add-Line ("          ${InputName}-file: '" + $candidate + "'")
            return
        }
    }
    Add-Line ("          ${InputName}: '" + $Default + "'")
}
$projectRoot = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProjectPath))
if ($projectRoot -notmatch '^[A-Za-z]:\\' -or -not (Test-Path -LiteralPath $projectRoot -PathType Container)) { throw 'ProjectPath must be an existing local Windows directory.' }
$projectRoot = $projectRoot.TrimEnd('\')
Assert-NoLink $projectRoot
$workflowDirectory = Join-Path $projectRoot '.github\workflows'
$workflowPath = Join-Path $workflowDirectory 'project-checks.yml'
if (Test-Path -LiteralPath $workflowPath) { throw "Workflow already exists; nothing was overwritten: $workflowPath" }
Assert-NoLink $workflowDirectory

# Scan source without descending into environments, dependencies, Git or linked trees.
$pythonFiles = [Collections.Generic.List[string]]::new()
$pending = [Collections.Generic.Stack[string]]::new()
$pending.Push($projectRoot)
$excluded = @('.git', '.venv', 'venv', 'env', 'node_modules', '__pycache__', '.tox', '.pytest_cache', 'build', 'dist')
while ($pending.Count) {
    $directory = $pending.Pop()
    foreach ($item in Get-ChildItem -LiteralPath $directory -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($item.PSIsContainer) {
            if ($item.Name -notin $excluded) { $pending.Push($item.FullName) }
        } elseif ($item.Extension -eq '.py') {
            $pythonFiles.Add($item.FullName.Substring($projectRoot.Length + 1).Replace('\', '/'))
        }
    }
}
$hasPython = $pythonFiles.Count -gt 0
$hasNode = Is-File 'package.json'
$hasPowerShell = (Is-File 'tests/test-workflow.ps1') -and (Is-File 'tests/test-ci.ps1')
$chosen = $Preset
if ($Preset -eq 'Auto') {
    if ($hasPython -and $hasNode) { $chosen = 'Mixed' }
    elseif ($hasPython) { $chosen = 'Python' }
    elseif ($hasNode) { $chosen = 'Node' }
    elseif ($hasPowerShell) { $chosen = 'PowerShell' }
    else {
        return [pscustomobject]@{Status='NotNeeded'; Preset='Auto'; WorkflowPath=$workflowPath; Reason='No recognized code or existing checks; no CI file was created.'}
    }
}
$wantsPython = $chosen -in @('Python', 'Mixed')
$wantsNode = $chosen -in @('Node', 'Mixed')
if ($wantsPython -and -not $hasPython) { throw 'No Python source was found; review the project before adding Python CI.' }
if ($wantsNode -and -not $hasNode) { throw 'Node CI requires an existing package.json.' }
if ($chosen -eq 'PowerShell' -and -not $hasPowerShell) { throw 'PowerShell preset requires tests/test-workflow.ps1 and tests/test-ci.ps1.' }
if ($PythonVersion -and -not $wantsPython) { throw '-PythonVersion requires a Python or Mixed project.' }
if ($NodeVersion -and -not $wantsNode) { throw '-NodeVersion requires a Node or Mixed project.' }
$nodeScripts = @()
$nodeVersionFiles = @('.nvmrc', '.node-version')
if ($wantsNode) {
    foreach ($otherManager in @('yarn.lock', 'pnpm-lock.yaml', 'bun.lock', 'bun.lockb', '.yarnrc.yml', 'pnpm-workspace.yaml')) {
        if (Test-Path -LiteralPath (Join-Path $projectRoot $otherManager)) { throw "Unsupported package manager marker $otherManager; existing package-manager files were preserved." }
    }
    $package = Read-Text 'package.json' | ConvertFrom-Json
    if ($package.PSObject.Properties['packageManager'] -and $package.packageManager -notmatch '^npm@') { throw 'Only npm projects are supported; packageManager was preserved.' }
    if (-not (Is-File 'package-lock.json')) { throw 'npm CI requires an existing package-lock.json; no lockfile was created.' }
    # npm validates its own lockfile; legitimate v2/v3 locks contain an empty JSON key.
    if ($package.PSObject.Properties['scripts']) {
        foreach ($name in @('test', 'lint', 'build')) {
            if ($package.scripts.PSObject.Properties[$name] -and -not [string]::IsNullOrWhiteSpace([string]$package.scripts.$name)) { $nodeScripts += $name }
        }
    }
    if ($package.PSObject.Properties['engines'] -and $package.engines.PSObject.Properties['node']) { $nodeVersionFiles += 'package.json' }
}
$requirements = @()
$pythonCommands = [Collections.Generic.List[object]]::new()
$pythonCheck = $null
if ($wantsPython) {
    foreach ($relative in @('requirements.txt', 'requirements-dev.txt', 'requirements-test.txt', 'requirements/base.txt', 'requirements/dev.txt', 'requirements/test.txt')) {
        if (Is-File $relative) { $requirements += $relative }
    }
    $testFiles = @($pythonFiles | Where-Object {[IO.Path]::GetFileName($_) -match '^test_.*\.py$|.*_test\.py$'})
    $pytestDeclared = $false
    foreach ($relative in $requirements) {
        if ((Read-Text $relative) -match '(?im)^\s*pytest(?:\[|\s|[<>=!~;]|$)') { $pytestDeclared = $true }
    }
    $pytestConfig = (Is-File 'pytest.ini') -or ((Is-File 'pyproject.toml') -and (Read-Text 'pyproject.toml') -match '(?m)^\s*\[tool\.pytest\.ini_options\]') -or ((Is-File 'setup.cfg') -and (Read-Text 'setup.cfg') -match '(?m)^\s*\[tool:pytest\]')
    if ($pytestConfig -or ($testFiles.Count -gt 0 -and $pytestDeclared)) {
        if (-not $pytestDeclared) { throw 'pytest configuration exists, but pytest is not declared in supported requirements files. Review its existing install command before adding CI.' }
        $pythonCheck = 'pytest'
        $pythonCommands.Add([pscustomobject]@{Name='Run existing pytest tests'; Command='python -m pytest'})
    } elseif ($testFiles.Count -gt 0) {
        foreach ($relative in $testFiles) {
            if ((Read-Text $relative) -notmatch '(?m)^\s*(?:import\s+unittest\b|from\s+unittest\s+import\b)') { throw "Cannot infer the existing test runner for $relative; declare pytest in supported requirements or review the workflow manually." }
            if ($relative -notmatch '^tests/|^[^/]+$' -or [IO.Path]::GetFileName($relative) -notmatch '^test_') { throw "unittest auto-detection supports test_*.py in the root or tests/: $relative" }
        }
        $pythonCheck = 'unittest'
        if (@($testFiles | Where-Object {$_ -match '^tests/'}).Count) { $pythonCommands.Add([pscustomobject]@{Name='Run existing unittest tests'; Command="python -m unittest discover -s 'tests' -v"}) }
        if (@($testFiles | Where-Object {$_ -notmatch '/'}).Count) { $pythonCommands.Add([pscustomobject]@{Name='Run root unittest tests'; Command='python -m unittest discover -v'}) }
    } else {
        $pythonCheck = 'CompileOnly'
        $targets = @($pythonFiles | Where-Object {$_ -notmatch '/'} | Sort-Object)
        $targets += @($pythonFiles | Where-Object {$_ -match '/'} | ForEach-Object {($_ -split '/')[0]} | Sort-Object -Unique)
        $command = 'python -m compileall -q ' + (($targets | ForEach-Object {Quote-PS $_}) -join ' ')
        $pythonCommands.Add([pscustomobject]@{Name='Compile Python source only (no tests detected)'; Command=$command})
    }
}
if ($wantsNode -and $nodeScripts.Count -eq 0 -and -not $wantsPython) {
    return [pscustomobject]@{Status='NotNeeded'; Preset=$chosen; WorkflowPath=$workflowPath; Reason='No existing npm test/lint/build scripts; no CI file was created.'}
}
$lines = [Collections.Generic.List[string]]::new()
Add-Line 'name: Project checks'
Add-Line ''
Add-Line 'on:'
Add-Line '  push:'
Add-Line '  pull_request:'
Add-Line '  workflow_dispatch:'
Add-Line ''
Add-Line 'permissions:'
Add-Line '  contents: read'
Add-Line ''
Add-Line 'jobs:'
if ($chosen -eq 'PowerShell') {
    Add-Line '  powershell:'
    Add-Line '    runs-on: windows-latest'
    Add-Line '    strategy:'
    Add-Line '      fail-fast: false'
    Add-Line '      matrix:'
    Add-Line '        shell: [pwsh, powershell]'
    Add-Line '    defaults:'
    Add-Line '      run:'
    Add-Line '        shell: ${{ matrix.shell }}'
    Add-Line '    steps:'
    Add-Line '      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1'
    Add-Run 'Test workflow behavior' "& './tests/test-workflow.ps1'"
    Add-Run 'Test CI generation behavior' "& './tests/test-ci.ps1'"
} else {
    if ($wantsPython) {
        Add-Line '  python:'
        Add-Line '    runs-on: windows-latest'
        Add-Line '    defaults:'
        Add-Line '      run:'
        Add-Line '        shell: pwsh'
        Add-Line '    steps:'
        Add-Line '      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1'
        Add-Line '      - uses: actions/setup-python@5fda3b95a4ea91299a34e894583c3862153e4b97 # v7.0.0'
        $pythonVersionFiles = @('.python-version')
        if ((Is-File 'pyproject.toml') -and (Read-Text 'pyproject.toml') -match '(?m)^\s*requires-python\s*=') { $pythonVersionFiles += 'pyproject.toml' }
        Add-Version $PythonVersion $pythonVersionFiles '3.x' 'python-version'
        if ($requirements.Count) { Add-Run 'Install existing Python requirements' ('python -m pip install ' + (($requirements | ForEach-Object {'-r ' + (Quote-PS $_)}) -join ' ')) }
        foreach ($check in $pythonCommands) { Add-Run $check.Name $check.Command }
    }
    if ($wantsNode -and $nodeScripts.Count) {
        Add-Line '  node:'
        Add-Line '    runs-on: windows-latest'
        Add-Line '    defaults:'
        Add-Line '      run:'
        Add-Line '        shell: pwsh'
        Add-Line '    steps:'
        Add-Line '      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1'
        Add-Line '      - uses: actions/setup-node@949feb2413d6458794dcd2491c4babbbce0c15c1 # v7.1.0'
        Add-Version $NodeVersion $nodeVersionFiles 'lts/*' 'node-version'
        Add-Run 'Install from existing npm lockfile' 'npm ci'
        foreach ($name in $nodeScripts) { Add-Run ("Run existing npm $name script") ("npm run $name") }
    }
}
$content = ($lines -join "`n") + "`n"
$result = [pscustomobject]@{Status='Preview'; Preset=$chosen; WorkflowPath=$workflowPath; PythonCheck=$pythonCheck; NodeScripts=$nodeScripts; Reason='Only project-checks.yml is generated; existing checks and dependency files are reused.'}
if (-not $PSCmdlet.ShouldProcess($workflowPath, "Create $chosen GitHub Actions workflow")) { return $result }
[void][IO.Directory]::CreateDirectory($workflowDirectory)
# CreateNew protects an existing workflow even if another process creates it after preflight.
$stream = [IO.File]::Open($workflowPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($content)
    $stream.Write($bytes, 0, $bytes.Length)
} finally { $stream.Dispose() }
$result.Status = 'Created'
return $result
