#requires -Version 5.1
<#
.SYNOPSIS
Back up a local project, including uncommitted files and standalone Git history.
.EXAMPLE
.\backup-project.ps1 -ProjectPath D:\Projects\demo
.EXAMPLE
.\backup-project.ps1 -ProjectPath D:\Projects\demo -BackupRoot F:\Backups -Exclude 'data/cache', '*.tmp'
.NOTES
Default destination: D:\ProjectBackups. ZIP is not encrypted.
Secrets and reproducible environments are excluded; see the manifest.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)][string]$ProjectPath,
    [string]$BackupRoot = 'D:\ProjectBackups',
    [string[]]$Exclude = @(),
    [switch]$IncludeSecrets
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
function Get-LocalPath([string]$Value) {
    $full = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Value))
    if ($full -notmatch '^[A-Za-z]:\\') { throw "Use a local Windows filesystem path: $Value" }
    return $full.TrimEnd('\')
}
function Assert-NoLinkAncestor([string]$Path) {
    $cursor = $Path
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (-not $item.PSIsContainer) { throw "Not a directory: $cursor" }
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked directory is not supported: $cursor" }
        }
        $parent = [IO.Directory]::GetParent($cursor)
        if ($null -eq $parent) { break }
        $cursor = $parent.FullName
    }
}
function Get-StreamHash([IO.Stream]$Stream) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Stream))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Get-ContentHash([string]$Path) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { return Get-StreamHash $stream }
    finally { $stream.Dispose() }
}
function Get-SkipReason([string]$Relative, [string]$Leaf, [bool]$IsDirectory) {
    # Keep Git metadata intact, including refs whose names resemble excluded files.
    if ($Relative -match '(^|/)\.git(/|$)') { return $null }
    if ($IsDirectory -and $Leaf -in @('.venv', 'node_modules', '__pycache__', '.pytest_cache', '.mypy_cache', '.ruff_cache', '.tox', '.nox', '.npm', '.next')) {
        return 'Reproducible environment/cache'
    }
    if (-not $IncludeSecrets -and -not $IsDirectory) {
        $envFile = ($Leaf -eq '.env' -or $Leaf -like '.env.*')
        $example = $Leaf -in @('.env.example', '.env.sample', '.env.template')
        if (($envFile -and -not $example) -or $Leaf -match '\.(pem|key|pfx|p12)$' -or
            $Leaf -in @('id_rsa', 'id_ed25519', 'id_ecdsa', '.npmrc', '.pypirc', '.netrc')) {
            return 'Potential local secret'
        }
    }
    foreach ($pattern in $patterns) {
        if ($Relative -like $pattern -or $Leaf -like $pattern) { return "User exclusion: $pattern" }
    }
    return $null
}
function Get-ProjectSnapshot {
    $files = [Collections.Generic.List[object]]::new()
    $directories = [Collections.Generic.List[string]]::new()
    $skipped = [Collections.Generic.List[object]]::new()
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($sourcePath)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force | Sort-Object Name)) {
            $relative = $item.FullName.Substring($sourcePath.Length + 1).Replace('\', '/')
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked file/directory is not supported: $relative" }
            if ($item.Name -eq '.git' -and -not $item.PSIsContainer) { throw "Git worktrees/submodules with an external .git file are not supported: $relative" }
            if ($relative -match '(^|/)\.git/' -and $item.Name -in @('commondir', 'alternates', 'http-alternates')) {
                throw "Git metadata references external storage; ordinary ZIP is insufficient: $relative"
            }
            if ($relative -match '(^|/)\.git/' -and $item.Name -like '*.lock') { throw "Git is busy or a lock needs inspection: $relative" }
            $reason = Get-SkipReason $relative $item.Name $item.PSIsContainer
            if ($reason) {
                $skipped.Add([pscustomobject]@{ Path = $relative; Reason = $reason })
                continue
            }
            if ($item.PSIsContainer) {
                $directories.Add($relative)
                $pending.Push($item.FullName)
            } else {
                $files.Add([pscustomobject]@{
                    Path = $relative; FullName = $item.FullName; Length = $item.Length
                    LastWriteUtc = $item.LastWriteTimeUtc.ToString('o')
                    SHA256 = Get-ContentHash $item.FullName
                })
            }
        }
    }
    return [pscustomobject]@{ Files = $files.ToArray(); Directories = $directories.ToArray(); Excluded = $skipped.ToArray() }
}
function Assert-SameSnapshot($Before, $After) {
    if ($Before.Files.Count -ne $After.Files.Count) { throw 'Source file set changed during backup. Retry with writers stopped.' }
    $map = @{}
    foreach ($file in $Before.Files) { $map[$file.Path] = $file }
    foreach ($file in $After.Files) {
        if (-not $map.ContainsKey($file.Path)) { throw "Source file appeared during backup: $($file.Path)" }
        $old = $map[$file.Path]
        if ($old.Length -ne $file.Length -or $old.SHA256 -ne $file.SHA256 -or $old.LastWriteUtc -ne $file.LastWriteUtc) {
            throw "Source file changed during backup: $($file.Path). Retry with writers stopped."
        }
    }
    $beforeDirs = (@($Before.Directories | Sort-Object) -join '|')
    $afterDirs = (@($After.Directories | Sort-Object) -join '|')
    $beforeExcluded = ConvertTo-Json -InputObject @($Before.Excluded | Sort-Object Path) -Compress
    $afterExcluded = ConvertTo-Json -InputObject @($After.Excluded | Sort-Object Path) -Compress
    if ($beforeDirs -ne $afterDirs -or $beforeExcluded -ne $afterExcluded) { throw 'Source directory/exclusion set changed during backup. Retry.' }
}

$sourcePath = Get-LocalPath $ProjectPath
$backupPath = Get-LocalPath $BackupRoot
if ($sourcePath.Length -le 2) { throw 'Refusing to back up an entire drive. Select a project directory.' }
if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) { throw "Project directory not found: $sourcePath" }
if ($backupPath.Length -eq 2) { $backupPath += '\' }
if ($backupPath.Equals($sourcePath, [StringComparison]::OrdinalIgnoreCase) -or
    $backupPath.StartsWith($sourcePath + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'BackupRoot must be outside the project directory.'
}
Assert-NoLinkAncestor $sourcePath
Assert-NoLinkAncestor $backupPath
$patterns = @()
foreach ($pattern in $Exclude) {
    $normalized = $pattern.Replace('\', '/').TrimEnd('/')
    if (-not $normalized -or $normalized.StartsWith('/') -or $normalized.Contains(':') -or $normalized -match '(^|/)\.\.(/|$)') {
        throw "Exclusions must be relative wildcard patterns: $pattern"
    }
    $patterns += $normalized
}
$projectName = [IO.Path]::GetFileName($sourcePath)
$destinationDirectory = Join-Path $backupPath $projectName
if ($destinationDirectory.Equals($sourcePath, [StringComparison]::OrdinalIgnoreCase) -or
    $destinationDirectory.StartsWith($sourcePath + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Computed backup destination would be inside the project.'
}
Assert-NoLinkAncestor $destinationDirectory
if (-not $PSCmdlet.ShouldProcess($sourcePath, "Create and verify ZIP backup in $destinationDirectory")) { return }
if ($IncludeSecrets) { Write-Warning 'IncludeSecrets enabled. ZIP is not encrypted; protect the backup location.' }
Write-Warning 'Git history is included and may contain previously committed secrets. Close programs that are writing project files.'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$started = [DateTimeOffset]::Now
$snapshot = Get-ProjectSnapshot
[void][IO.Directory]::CreateDirectory($destinationDirectory)
$stamp = $started.ToString('yyyyMMdd-HHmmss-fff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$baseName = $projectName + '-' + $stamp
$zipPath = Join-Path $destinationDirectory ($baseName + '.zip')
$manifestPath = Join-Path $destinationDirectory ($baseName + '.manifest.json')
$checksumPath = Join-Path $destinationDirectory ($baseName + '.sha256')
$partialZip = $zipPath + '.partial'
$partialManifest = $manifestPath + '.partial'
$partialChecksum = $checksumPath + '.partial'
try {
    $zipStream = [IO.File]::Open($partialZip, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $archive = [IO.Compression.ZipArchive]::new($zipStream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($directory in $snapshot.Directories) { [void]$archive.CreateEntry($directory + '/') }
            foreach ($file in $snapshot.Files) {
                $entry = $archive.CreateEntry($file.Path, [IO.Compression.CompressionLevel]::Optimal)
                $time = [DateTimeOffset]::Parse($file.LastWriteUtc)
                if ($time.Year -ge 1980 -and $time.Year -le 2107) { $entry.LastWriteTime = $time }
                $inputStream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                try {
                    $outputStream = $entry.Open()
                    try { $inputStream.CopyTo($outputStream) }
                    finally { $outputStream.Dispose() }
                } finally { $inputStream.Dispose() }
            }
        } finally { $archive.Dispose() }
    } finally { $zipStream.Dispose() }

    $verify = [IO.Compression.ZipFile]::OpenRead($partialZip)
    try {
        if ($verify.Entries.Count -ne ($snapshot.Files.Count + $snapshot.Directories.Count)) { throw 'ZIP entry count mismatch.' }
        foreach ($file in $snapshot.Files) {
            $entry = $verify.GetEntry($file.Path)
            if ($null -eq $entry -or $entry.Length -ne $file.Length) { throw "ZIP entry missing or truncated: $($file.Path)" }
            $stream = $entry.Open()
            try { $hash = Get-StreamHash $stream }
            finally { $stream.Dispose() }
            if ($hash -ne $file.SHA256) { throw "ZIP content mismatch: $($file.Path)" }
        }
    } finally { $verify.Dispose() }
    $after = Get-ProjectSnapshot
    Assert-SameSnapshot $snapshot $after

    $manifest = [ordered]@{
        FormatVersion = 1; Source = $sourcePath; Archive = [IO.Path]::GetFileName($zipPath)
        StartedAt = $started.ToString('o'); VerifiedAt = [DateTimeOffset]::Now.ToString('o')
        PowerShell = $PSVersionTable.PSVersion.ToString(); IncludeSecrets = [bool]$IncludeSecrets
        FileCount = $snapshot.Files.Count; DirectoryCount = $snapshot.Directories.Count
        Directories = @($snapshot.Directories)
        Files = @($snapshot.Files | Select-Object Path, Length, LastWriteUtc, SHA256)
        Excluded = @($snapshot.Excluded)
        DefaultExcludedDirectories = @('.venv', 'node_modules', '__pycache__', '.pytest_cache', '.mypy_cache', '.ruff_cache', '.tox', '.nox', '.npm', '.next')
        UserExclusions = $patterns
        Notes = @('ZIP is not encrypted and does not preserve NTFS ACLs or alternate data streams.',
            'Git history may contain secrets. Filename rules do not detect secrets inside arbitrary files.',
            'Two source scans detect changes; this is not an atomic VSS snapshot.',
            'Recreate environments from dependency manifests; restore local secrets separately.')
    }
    $utf8 = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($partialManifest, ($manifest | ConvertTo-Json -Depth 8), $utf8)
    $zipHash = Get-ContentHash $partialZip
    $manifestHash = Get-ContentHash $partialManifest
    $checksums = $zipHash + '  ' + [IO.Path]::GetFileName($zipPath) + [Environment]::NewLine +
        $manifestHash + '  ' + [IO.Path]::GetFileName($manifestPath) + [Environment]::NewLine
    [IO.File]::WriteAllText($partialChecksum, $checksums, $utf8)
    # File.Move fails on collisions; only fully verified archives receive a .zip name.
    [IO.File]::Move($partialManifest, $manifestPath)
    [IO.File]::Move($partialChecksum, $checksumPath)
    [IO.File]::Move($partialZip, $zipPath)
    Write-Host "Verified backup: $zipPath"
    Write-Host "Files: $($snapshot.Files.Count); excluded paths: $($snapshot.Excluded.Count)"
    [pscustomobject]@{ Archive = $zipPath; Manifest = $manifestPath; Checksum = $checksumPath; SHA256 = $zipHash; FileCount = $snapshot.Files.Count }
} catch {
    Write-Warning "Backup failed. Any .partial files in $destinationDirectory are NOT verified backups. Originals were not changed."
    throw
}
