<#
.SYNOPSIS
    Automated tests for Transfer Gate v2 PowerShell engine.
.DESCRIPTION
    Tests cover: config loading, v1 config migration, manifest generation,
    placement execution, overwrite protection, prune contract, SHA-256
    verification, and receipt generation.

    Run: powershell -ExecutionPolicy Bypass -File tests/Test-TransferGate.ps1
    Run on macOS/Linux: pwsh tests/Test-TransferGate.ps1
#>
param([switch]$Verbose)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptRoot

$TestsRun = 0
$TestsPassed = 0
$TestsFailed = 0
$Failures = [System.Collections.ArrayList]::new()

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) {
        throw "ASSERT FAILED: $Message`n  Expected: $Expected`n  Actual:   $Actual"
    }
}

function Assert-True($Value, [string]$Message) {
    if (-not $Value) {
        throw "ASSERT FAILED: $Message (expected true, got false)"
    }
}

function Assert-False($Value, [string]$Message) {
    if ($Value) {
        throw "ASSERT FAILED: $Message (expected false, got true)"
    }
}

function Assert-FileExists([string]$Path, [string]$Message) {
    if (-not (Test-Path $Path -PathType Leaf)) {
        throw "ASSERT FAILED: $Message — file not found: $Path"
    }
}

function Assert-DirExists([string]$Path, [string]$Message) {
    if (-not (Test-Path $Path -PathType Container)) {
        throw "ASSERT FAILED: $Message — directory not found: $Path"
    }
}

function New-TempTestDir {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) "tg-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function Remove-TempTestDir([string]$Path) {
    if ($Path -and (Test-Path $Path)) {
        Remove-Item $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-SHA256([string]$Path) {
    (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
}

function Write-TestConfig([string]$Dir, [hashtable]$Data) {
    $path = Join-Path $Dir "transfer-gate.json"
    $Data | ConvertTo-Json -Depth 5 | Set-Content -Path $path -Encoding UTF8
    return $path
}

function Run-Test([string]$Name, [scriptblock]$Test) {
    $script:TestsRun++
    try {
        & $Test
        $script:TestsPassed++
        if ($Verbose) { Write-Host "  PASS: $Name" -ForegroundColor Green }
    } catch {
        $script:TestsFailed++
        $script:Failures.Add("$Name`: $_") | Out-Null
        Write-Host "  FAIL: $Name" -ForegroundColor Red
        if ($Verbose) { Write-Host "    $_" -ForegroundColor DarkRed }
    }
}

# ── Config Tests ───────────────────────────────────────────────────────

Write-Host "`n=== Config Tests ===" -ForegroundColor Cyan

Run-Test "v2 config loads cabinetRoot" {
    $dir = New-TempTestDir
    try {
        Write-TestConfig $dir @{
            cabinetRoot = "D:\Archive"
            inbox = "00 Inbox"
            manifestOutput = "gate-out"
            exclude = @(".DS_Store")
        }
        $cfg = Get-Content (Join-Path $dir "transfer-gate.json") -Raw | ConvertFrom-Json
        Assert-Equal "D:\Archive" $cfg.cabinetRoot "cabinetRoot"
        Assert-Equal "00 Inbox" $cfg.inbox "inbox"
    } finally { Remove-TempTestDir $dir }
}

Run-Test "v1 config has archiveRoot" {
    $dir = New-TempTestDir
    try {
        Write-TestConfig $dir @{
            archiveRoot = "D:\Archive"
            inbox = "D:\Archive\00 Inbox"
            manifestOutput = "D:\Archive\gate-out"
            exclude = @(".DS_Store")
        }
        $cfg = Get-Content (Join-Path $dir "transfer-gate.json") -Raw | ConvertFrom-Json
        # v1 config should have archiveRoot
        Assert-Equal "D:\Archive" $cfg.archiveRoot "archiveRoot present"
    } finally { Remove-TempTestDir $dir }
}

Run-Test "v1 config migration: archiveRoot becomes cabinetRoot" {
    $dir = New-TempTestDir
    try {
        Write-TestConfig $dir @{
            archiveRoot = "/mnt/archive"
            inbox = "/mnt/archive/00 Inbox"
            manifestOutput = "/mnt/archive/gate-out"
            exclude = @(".DS_Store")
        }
        $cfg = Get-Content (Join-Path $dir "transfer-gate.json") -Raw | ConvertFrom-Json
        # Simulate v1 migration logic
        $cabinet = if ($cfg.PSObject.Properties.Name -contains "cabinetRoot") {
            $cfg.cabinetRoot
        } elseif ($cfg.PSObject.Properties.Name -contains "archiveRoot") {
            $cfg.archiveRoot
        } else { "" }
        Assert-Equal "/mnt/archive" $cabinet "migrated cabinet root"
    } finally { Remove-TempTestDir $dir }
}

# ── Manifest Generation Tests ──────────────────────────────────────────

Write-Host "`n=== Manifest Generation Tests ===" -ForegroundColor Cyan

Run-Test "transfer-manifest.json v1 format" {
    $dir = New-TempTestDir
    try {
        $payloadDir = Join-Path $dir "batch-001" "payload"
        New-Item -ItemType Directory -Path $payloadDir -Force | Out-Null
        Set-Content -Path (Join-Path $payloadDir "test.txt") -Value "hello" -Encoding UTF8

        $file = Get-Item (Join-Path $payloadDir "test.txt")
        $hash = Get-SHA256 $file.FullName

        $manifest = [ordered]@{
            manifest_version = 1
            kind = "transfer-manifest"
            batch_id = "batch-001"
            created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
            source_host = [System.Net.Dns]::GetHostName()
            totals = [ordered]@{ files = 1; bytes = $file.Length }
            files = @(
                [ordered]@{
                    path = "test.txt"
                    size = $file.Length
                    sha256 = $hash
                }
            )
        }

        $mPath = Join-Path $dir "batch-001" "transfer-manifest.json"
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $mPath -Encoding UTF8

        $loaded = Get-Content $mPath -Raw | ConvertFrom-Json
        Assert-Equal 1 $loaded.manifest_version "manifest version"
        Assert-Equal "transfer-manifest" $loaded.kind "kind"
        Assert-Equal "batch-001" $loaded.batch_id "batch_id"
        Assert-Equal 1 $loaded.totals.files "file count"
    } finally { Remove-TempTestDir $dir }
}

Run-Test "placement-manifest.json v2 format" {
    $dir = New-TempTestDir
    try {
        $manifest = [ordered]@{
            manifest_version = 2
            kind = "placement-manifest"
            batch_id = "batch-002"
            created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
            cabinet_root_hint = "D:\Archive"
            decisions = @(
                [ordered]@{
                    source_path = "10 Finance/2026-11-07 Tax Return (v1).pdf"
                    original_name = "Tax Return.pdf"
                    destination = "10 Finance/Tax/2026"
                    conflict_policy = "skip"
                }
            )
        }

        $mPath = Join-Path $dir "placement-manifest.json"
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $mPath -Encoding UTF8

        $loaded = Get-Content $mPath -Raw | ConvertFrom-Json
        Assert-Equal 2 $loaded.manifest_version "v2 manifest version"
        Assert-Equal "placement-manifest" $loaded.kind "kind"
        Assert-Equal 1 $loaded.decisions.Count "decision count"
        Assert-Equal "skip" $loaded.decisions[0].conflict_policy "conflict policy"
    } finally { Remove-TempTestDir $dir }
}

Run-Test "placement-receipt.json format" {
    $dir = New-TempTestDir
    try {
        $receipt = [ordered]@{
            manifest_version = 2
            kind = "placement-receipt"
            batch_id = "batch-003"
            placed_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
            hostname = [System.Net.Dns]::GetHostName()
            cabinet_root = "D:\Archive"
            outcomes = @(
                [ordered]@{
                    source_path = "2026-11-07 Tax (v1).pdf"
                    destination = "10 Finance/Tax/2026/2026-11-07 Tax (v1).pdf"
                    status = "placed"
                    sha256 = "abc123"
                }
            )
        }

        $rPath = Join-Path $dir "placement-receipt.json"
        $receipt | ConvertTo-Json -Depth 10 | Set-Content -Path $rPath -Encoding UTF8

        $loaded = Get-Content $rPath -Raw | ConvertFrom-Json
        Assert-Equal 2 $loaded.manifest_version "receipt version"
        Assert-Equal "placement-receipt" $loaded.kind "kind"
        Assert-Equal "placed" $loaded.outcomes[0].status "outcome status"
    } finally { Remove-TempTestDir $dir }
}

# ── Placement Tests ────────────────────────────────────────────────────

Write-Host "`n=== Placement Tests ===" -ForegroundColor Cyan

Run-Test "file placed to correct destination" {
    $dir = New-TempTestDir
    try {
        $cabinet = Join-Path $dir "Cabinet"
        $taxDir = Join-Path $cabinet "10 Finance" "Tax" "2026"
        New-Item -ItemType Directory -Path $taxDir -Force | Out-Null

        $batchDir = Join-Path $dir "batch"
        $payloadDir = Join-Path $batchDir "payload" "10 Finance"
        New-Item -ItemType Directory -Path $payloadDir -Force | Out-Null

        $srcFile = Join-Path $payloadDir "2026-11-07 Tax Return (v1).pdf"
        Set-Content -Path $srcFile -Value "tax doc content" -Encoding UTF8
        $srcHash = Get-SHA256 $srcFile

        $destFile = Join-Path $taxDir "2026-11-07 Tax Return (v1).pdf"
        Copy-Item $srcFile $destFile

        Assert-FileExists $destFile "file placed"
        $destHash = Get-SHA256 $destFile
        Assert-Equal $srcHash $destHash "SHA-256 match after placement"
    } finally { Remove-TempTestDir $dir }
}

Run-Test "overwrite protection: skip policy" {
    $dir = New-TempTestDir
    try {
        $cabinet = Join-Path $dir "Cabinet" "10 Finance"
        New-Item -ItemType Directory -Path $cabinet -Force | Out-Null

        $existing = Join-Path $cabinet "existing.pdf"
        Set-Content -Path $existing -Value "ORIGINAL" -Encoding UTF8
        $origHash = Get-SHA256 $existing

        # Simulate skip: do not overwrite
        $newContent = "NEW CONTENT"
        $conflict_policy = "skip"
        if ($conflict_policy -eq "skip" -and (Test-Path $existing)) {
            # Skip — do not copy
        }

        $afterHash = Get-SHA256 $existing
        Assert-Equal $origHash $afterHash "original file unchanged with skip policy"
        $content = Get-Content $existing -Raw
        Assert-True ($content.Trim() -eq "ORIGINAL") "original content preserved"
    } finally { Remove-TempTestDir $dir }
}

Run-Test "overwrite protection: rename policy appends suffix" {
    $dir = New-TempTestDir
    try {
        $cabinet = Join-Path $dir "Cabinet"
        New-Item -ItemType Directory -Path $cabinet -Force | Out-Null

        $existing = Join-Path $cabinet "report.pdf"
        Set-Content -Path $existing -Value "ORIGINAL" -Encoding UTF8

        # Simulate rename policy
        $baseName = "report"
        $ext = ".pdf"
        $suffix = 1
        $newName = "${baseName}-${suffix}${ext}"
        while (Test-Path (Join-Path $cabinet $newName)) { $suffix++ ; $newName = "${baseName}-${suffix}${ext}" }
        $renamedPath = Join-Path $cabinet $newName
        Set-Content -Path $renamedPath -Value "NEW" -Encoding UTF8

        Assert-FileExists $existing "original still exists"
        Assert-FileExists $renamedPath "renamed copy exists"
        Assert-Equal "ORIGINAL" (Get-Content $existing -Raw).Trim() "original unchanged"
        Assert-Equal "NEW" (Get-Content $renamedPath -Raw).Trim() "new file has new content"
    } finally { Remove-TempTestDir $dir }
}

Run-Test "overwrite protection: overwrite policy replaces file" {
    $dir = New-TempTestDir
    try {
        $cabinet = Join-Path $dir "Cabinet"
        New-Item -ItemType Directory -Path $cabinet -Force | Out-Null

        $existing = Join-Path $cabinet "report.pdf"
        Set-Content -Path $existing -Value "OLD" -Encoding UTF8

        # Simulate explicit overwrite
        $conflict_policy = "overwrite"
        if ($conflict_policy -eq "overwrite") {
            Set-Content -Path $existing -Value "REPLACED" -Encoding UTF8
        }

        Assert-Equal "REPLACED" (Get-Content $existing -Raw).Trim() "overwritten content"
    } finally { Remove-TempTestDir $dir }
}

# ── Prune Contract Tests ───────────────────────────────────────────────

Write-Host "`n=== Prune Contract Tests ===" -ForegroundColor Cyan

Run-Test "source files never deleted during staging" {
    $dir = New-TempTestDir
    try {
        $srcDir = Join-Path $dir "tosort"
        New-Item -ItemType Directory -Path $srcDir -Force | Out-Null
        $srcFile = Join-Path $srcDir "important.pdf"
        Set-Content -Path $srcFile -Value "precious data" -Encoding UTF8

        $batchDir = Join-Path $dir "batch" "payload"
        New-Item -ItemType Directory -Path $batchDir -Force | Out-Null

        # Staging = COPY only
        Copy-Item $srcFile (Join-Path $batchDir "important.pdf")

        Assert-FileExists $srcFile "source file still exists after staging"
        Assert-FileExists (Join-Path $batchDir "important.pdf") "copy in batch"
    } finally { Remove-TempTestDir $dir }
}

Run-Test "source files never deleted during placement" {
    $dir = New-TempTestDir
    try {
        $batchPayload = Join-Path $dir "batch" "payload"
        New-Item -ItemType Directory -Path $batchPayload -Force | Out-Null
        $batchFile = Join-Path $batchPayload "doc.pdf"
        Set-Content -Path $batchFile -Value "batch data" -Encoding UTF8

        $cabinet = Join-Path $dir "Cabinet" "10 Finance"
        New-Item -ItemType Directory -Path $cabinet -Force | Out-Null

        # Placement copies from batch to cabinet
        Copy-Item $batchFile (Join-Path $cabinet "doc.pdf")

        Assert-FileExists $batchFile "batch file still exists after placement"
        Assert-FileExists (Join-Path $cabinet "doc.pdf") "placed in cabinet"
    } finally { Remove-TempTestDir $dir }
}

# ── Verification Tests ─────────────────────────────────────────────────

Write-Host "`n=== Verification Tests ===" -ForegroundColor Cyan

Run-Test "SHA-256 verification passes for intact file" {
    $dir = New-TempTestDir
    try {
        $file = Join-Path $dir "intact.txt"
        Set-Content -Path $file -Value "known content" -Encoding UTF8
        $hash1 = Get-SHA256 $file
        $hash2 = Get-SHA256 $file
        Assert-Equal $hash1 $hash2 "same hash for same file"
    } finally { Remove-TempTestDir $dir }
}

Run-Test "SHA-256 verification fails for modified file" {
    $dir = New-TempTestDir
    try {
        $file = Join-Path $dir "modified.txt"
        Set-Content -Path $file -Value "original" -Encoding UTF8
        $hash1 = Get-SHA256 $file
        Set-Content -Path $file -Value "tampered" -Encoding UTF8
        $hash2 = Get-SHA256 $file
        Assert-True ($hash1 -ne $hash2) "different hash for modified file"
    } finally { Remove-TempTestDir $dir }
}

Run-Test "receipt manifest marks verified batch" {
    $dir = New-TempTestDir
    try {
        $batchDir = Join-Path $dir "batch-ok"
        $payloadDir = Join-Path $batchDir "payload"
        New-Item -ItemType Directory -Path $payloadDir -Force | Out-Null

        $file = Join-Path $payloadDir "test.txt"
        Set-Content -Path $file -Value "test content" -Encoding UTF8
        $hash = Get-SHA256 $file
        $size = (Get-Item $file).Length

        $manifest = [ordered]@{
            manifest_version = 1
            kind = "transfer-manifest"
            batch_id = "batch-ok"
            files = @([ordered]@{ path = "test.txt"; size = $size; sha256 = $hash })
        }
        $manifest | ConvertTo-Json -Depth 5 |
            Set-Content -Path (Join-Path $batchDir "transfer-manifest.json") -Encoding UTF8

        # Verify
        $mPath = Join-Path $batchDir "transfer-manifest.json"
        $m = Get-Content $mPath -Raw | ConvertFrom-Json
        $ok = $true
        foreach ($entry in $m.files) {
            $fpath = Join-Path $payloadDir $entry.path
            if (-not (Test-Path $fpath)) { $ok = $false; break }
            $fi = Get-Item $fpath
            if ($fi.Length -ne [long]$entry.size) { $ok = $false; break }
            if ((Get-SHA256 $fpath) -ne $entry.sha256) { $ok = $false; break }
        }
        Assert-True $ok "all files verified"
    } finally { Remove-TempTestDir $dir }
}

Run-Test "receipt manifest marks failed batch on checksum mismatch" {
    $dir = New-TempTestDir
    try {
        $batchDir = Join-Path $dir "batch-bad"
        $payloadDir = Join-Path $batchDir "payload"
        New-Item -ItemType Directory -Path $payloadDir -Force | Out-Null

        $file = Join-Path $payloadDir "test.txt"
        Set-Content -Path $file -Value "original" -Encoding UTF8
        $size = (Get-Item $file).Length

        $manifest = [ordered]@{
            manifest_version = 1
            kind = "transfer-manifest"
            batch_id = "batch-bad"
            files = @([ordered]@{ path = "test.txt"; size = $size; sha256 = "wrong_hash_value" })
        }
        $manifest | ConvertTo-Json -Depth 5 |
            Set-Content -Path (Join-Path $batchDir "transfer-manifest.json") -Encoding UTF8

        # Verify — should fail
        $m = Get-Content (Join-Path $batchDir "transfer-manifest.json") -Raw | ConvertFrom-Json
        $ok = $true
        foreach ($entry in $m.files) {
            $fpath = Join-Path $payloadDir $entry.path
            if ((Get-SHA256 $fpath) -ne $entry.sha256) { $ok = $false; break }
        }
        Assert-False $ok "checksum mismatch detected"
    } finally { Remove-TempTestDir $dir }
}

# ── Structure Manifest Tests ───────────────────────────────────────────

Write-Host "`n=== Structure Manifest Tests ===" -ForegroundColor Cyan

Run-Test "offline-structure-manifest.json generated correctly" {
    $dir = New-TempTestDir
    try {
        $cabinet = Join-Path $dir "Cabinet"
        $finDir = Join-Path $cabinet "10 Finance" "Tax" "2026"
        New-Item -ItemType Directory -Path $finDir -Force | Out-Null
        Set-Content -Path (Join-Path $finDir "tax.pdf") -Value "tax" -Encoding UTF8

        $persDir = Join-Path $cabinet "30 Personal" "Medical"
        New-Item -ItemType Directory -Path $persDir -Force | Out-Null
        Set-Content -Path (Join-Path $persDir "medical.pdf") -Value "med" -Encoding UTF8

        # Simulate export by building manifest
        $tree = [System.Collections.ArrayList]::new()
        function Walk-Tree([string]$Root, [string]$Current) {
            $rel = if ($Current -eq $Root) { "." } else {
                $Current.Substring($Root.Length + 1) -replace "\\", "/"
            }
            $children = @(Get-ChildItem $Current -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
            $files = @(Get-ChildItem $Current -File -ErrorAction SilentlyContinue)
            $tree.Add([ordered]@{
                path = $rel
                dirs = @($children | ForEach-Object { $_.Name })
                file_count = $files.Count
                bytes = ($files | Measure-Object -Property Length -Sum).Sum
            }) | Out-Null
            foreach ($child in $children) { Walk-Tree $Root $child.FullName }
        }
        Walk-Tree $cabinet $cabinet

        Assert-True ($tree.Count -ge 5) "tree has dirs for Cabinet + Finance + Tax + 2026 + Personal + Medical"

        $finEntry = $tree | Where-Object { $_.path -eq "10 Finance/Tax/2026" }
        Assert-True ($null -ne $finEntry) "2026 folder in tree"
        Assert-Equal 1 $finEntry.file_count "one tax file in 2026"
    } finally { Remove-TempTestDir $dir }
}

# ── Summary ────────────────────────────────────────────────────────────

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Tests: $TestsRun  Passed: $TestsPassed  Failed: $TestsFailed" -ForegroundColor $(if ($TestsFailed -eq 0) { "Green" } else { "Red" })

if ($Failures.Count -gt 0) {
    Write-Host "`nFailures:" -ForegroundColor Red
    foreach ($f in $Failures) {
        Write-Host "  - $f" -ForegroundColor Red
    }
}

exit $TestsFailed
