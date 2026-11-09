<#
.SYNOPSIS
    Transfer Gate v2 — offline batch verifier, structure exporter,
    file placement engine, and local HTTP server.
.DESCRIPTION
    Single-file offline tool for the air-gapped Cabinet archive.
    Extends v1 with file placement and an HTTP server for the HTML UI.

    Modes:
      verify  Scan inbox for inbound USB batches, verify every file against
              its transfer manifest (existence, size, SHA-256), emit receipt
              manifests. Receipts gate source deletion on the online side.
      export  Walk the Cabinet tree and emit offline-structure-manifest.json
              (directory paths and counts only — no file names or contents).
      place   Move verified batch files to their Cabinet destinations using
              placement-manifest.json in the batch directory.
      serve   Start a local HTTP server for the Transfer Gate HTML UI.
      all     Run verify then export (default).

    Two-phase prune contract (BLU-1845): nothing is deleted from online
    sources until a receipt with status "verified" returns through the gate.

    Config v2 format:
      - cabinetRoot (replaces archiveRoot; auto-migrated if archiveRoot found)
      - inbox and manifestOutput are relative to cabinetRoot (or absolute for v1 compat)

    Requirements: Windows PowerShell 5.1+ (ships with Windows 10/11).
    No Python, no pip, no network (for offline modes).

    Run:
      powershell -ExecutionPolicy Bypass -File .\transfer-gate.ps1
      powershell -ExecutionPolicy Bypass -File .\transfer-gate.ps1 -Mode verify
      powershell -ExecutionPolicy Bypass -File .\transfer-gate.ps1 -Mode place -BatchPath "D:\Archive\00 Inbox\batch-001"
      powershell -ExecutionPolicy Bypass -File .\transfer-gate.ps1 -Mode serve -Port 8080
      powershell -ExecutionPolicy Bypass -File .\transfer-gate.ps1 -Mode export -Quiet

    Companion config: transfer-gate.json (same folder as this script).
.PARAMETER Config
    Path to transfer-gate.json. Default: same directory as this script.
.PARAMETER Mode
    verify, export, place, serve, or all (default).
.PARAMETER BatchPath
    For place mode: path to the batch directory containing placement-manifest.json.
.PARAMETER Port
    For serve mode: HTTP listener port. Default: 8080.
.PARAMETER Quiet
    Suppress per-file output.
#>
param(
    [string]$Config,
    [ValidateSet("all", "verify", "export", "place", "serve")]
    [string]$Mode = "all",
    [string]$BatchPath,
    [int]$Port = 8080,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Version = "2.0.0"

# ── Config ──────────────────────────────────────────────────────────────

if (-not $Config) { $Config = Join-Path $PSScriptRoot "transfer-gate.json" }
if (-not (Test-Path $Config)) {
    Write-Host "ERROR: config not found: $Config" -ForegroundColor Red
    exit 2
}
$cfg = Get-Content $Config -Raw -Encoding UTF8 | ConvertFrom-Json

# Auto-migrate v1 archiveRoot -> cabinetRoot
$CabinetRoot = $null
if ($cfg.PSObject.Properties.Name -contains "cabinetRoot" -and $cfg.cabinetRoot) {
    $CabinetRoot = $cfg.cabinetRoot
} elseif ($cfg.PSObject.Properties.Name -contains "archiveRoot" -and $cfg.archiveRoot) {
    $CabinetRoot = $cfg.archiveRoot
    if (-not $Quiet) {
        Write-Host "NOTE: Using archiveRoot as cabinetRoot (v1 config auto-migration)" -ForegroundColor Yellow
    }
} else {
    Write-Host "ERROR: config must specify cabinetRoot (or archiveRoot for v1 compat)" -ForegroundColor Red
    exit 2
}

# Validate drive letter exists before any Join-Path or Test-Path call.
# PowerShell's Join-Path validates the PSDrive provider and throws
# "Cannot find drive" if the letter doesn't exist — .NET DriveInfo avoids this.
function Assert-DriveReady([string]$Path, [string]$Label) {
    if (-not [System.IO.Path]::IsPathRooted($Path)) { return }
    $root = [System.IO.Path]::GetPathRoot($Path)
    if ($root -match '^[A-Za-z]:\\') {
        $letter = $root[0]
        try {
            $di = [System.IO.DriveInfo]::new("${letter}")
            if (-not $di.IsReady) {
                Write-Host "ERROR: Drive ${letter}: is not ready." -ForegroundColor Red
                Write-Host "  '$Label' is set to: $Path" -ForegroundColor Yellow
                Write-Host "  Edit transfer-gate.json with the correct paths for this machine." -ForegroundColor Yellow
                exit 2
            }
        } catch {
            Write-Host "ERROR: Drive ${letter}: does not exist." -ForegroundColor Red
            Write-Host "  '$Label' is set to: $Path" -ForegroundColor Yellow
            Write-Host "  Edit transfer-gate.json with the correct paths for this machine." -ForegroundColor Yellow
            exit 2
        }
    }
}

Assert-DriveReady $CabinetRoot "cabinetRoot"

# Resolve inbox: relative to CabinetRoot unless it is an absolute path.
# Uses [IO.Path]::Combine instead of Join-Path to avoid PSDrive validation
# when the target drive letter does not exist as a PSDrive.
function Resolve-ConfigPath([string]$Value, [string]$Root) {
    if (-not $Value) { return $null }
    if ([System.IO.Path]::IsPathRooted($Value)) { return $Value }
    return [System.IO.Path]::Combine($Root, $Value)
}

$Inbox  = Resolve-ConfigPath $cfg.inbox $CabinetRoot
$OutDir = Resolve-ConfigPath $cfg.manifestOutput $CabinetRoot

$ExcludeSet = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@($cfg.exclude),
    [System.StringComparer]::OrdinalIgnoreCase
)

# ── Helpers ─────────────────────────────────────────────────────────────

function Get-SHA256([string]$Path) {
    (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
}

function Get-UtcStamp {
    [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function Test-Excluded([string]$Name) {
    $ExcludeSet.Contains($Name) -or $Name.StartsWith("._")
}

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Write-ManifestJson([string]$Path, $Obj) {
    $json = $Obj | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($Path, "$json`n", $script:Utf8NoBom)
}

function Ensure-Dir([string]$Path) {
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function ConvertTo-JsonSafe($Obj) {
    # ConvertTo-Json with sufficient depth for API responses
    $Obj | ConvertTo-Json -Depth 20 -Compress
}

# ── Verify ──────────────────────────────────────────────────────────────

function Invoke-Verify {
    if (-not (Test-Path $Inbox -PathType Container)) {
        Write-Host "ERROR: inbox not found: $Inbox" -ForegroundColor Red
        exit 2
    }
    $effectiveOut = if ($OutDir) { $OutDir } else { $Inbox }
    Ensure-Dir $effectiveOut

    $batchDirs = @(Get-ChildItem $Inbox -Directory |
        Where-Object { Test-Path (Join-Path $_.FullName "transfer-manifest.json") } |
        Sort-Object Name)

    $allReceipts = [System.Collections.ArrayList]::new()

    foreach ($bd in $batchDirs) {
        $r = [ordered]@{
            manifest_version  = 2
            kind              = "receipt-manifest"
            batch_id          = $bd.Name
            verified_utc      = Get-UtcStamp
            hostname          = [System.Net.Dns]::GetHostName()
            status            = "failed"
            files_total       = 0
            files_ok          = 0
            missing           = [System.Collections.ArrayList]::new()
            size_mismatch     = [System.Collections.ArrayList]::new()
            checksum_mismatch = [System.Collections.ArrayList]::new()
            extra             = [System.Collections.ArrayList]::new()
            errors            = [System.Collections.ArrayList]::new()
        }

        $mPath = Join-Path $bd.FullName "transfer-manifest.json"
        try {
            $m = Get-Content $mPath -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            $r.errors.Add("cannot read transfer-manifest.json: $_") | Out-Null
            $allReceipts.Add([PSCustomObject]$r) | Out-Null
            continue
        }

        if ($m.kind -ne "transfer-manifest") {
            $r.errors.Add("manifest kind is '$($m.kind)', expected 'transfer-manifest'") | Out-Null
            $allReceipts.Add([PSCustomObject]$r) | Out-Null
            continue
        }
        if ($m.batch_id) { $r.batch_id = $m.batch_id }

        $payloadRoot = Join-Path $bd.FullName "payload"
        $files = @($m.files)
        $r.files_total = $files.Count
        $listed = @{}

        foreach ($entry in $files) {
            $rel = $entry.path
            $listed[$rel] = $true
            $fpath = Join-Path $payloadRoot ($rel -replace "/", [IO.Path]::DirectorySeparatorChar)

            if (-not (Test-Path $fpath -PathType Leaf)) {
                $r.missing.Add($rel) | Out-Null
                continue
            }
            try {
                $fi = Get-Item $fpath
                if ($fi.Length -ne [long]$entry.size) {
                    $r.size_mismatch.Add([PSCustomObject][ordered]@{
                        path     = $rel
                        expected = $entry.size
                        actual   = $fi.Length
                    }) | Out-Null
                    continue
                }
                $digest = Get-SHA256 $fpath
            } catch {
                $r.errors.Add("cannot read ${rel}: $_") | Out-Null
                continue
            }
            if ($digest -ne $entry.sha256) {
                $r.checksum_mismatch.Add([PSCustomObject][ordered]@{
                    path     = $rel
                    expected = $entry.sha256
                    actual   = $digest
                }) | Out-Null
                continue
            }
            $r.files_ok++
        }

        # Detect extra files not listed in the manifest
        if (Test-Path $payloadRoot -PathType Container) {
            Get-ChildItem $payloadRoot -File -Recurse -ErrorAction SilentlyContinue |
                ForEach-Object {
                    $eRel = $_.FullName.Substring($payloadRoot.Length + 1) -replace "\\", "/"
                    if (-not $listed.ContainsKey($eRel) -and
                        -not $_.Name.StartsWith("._") -and
                        $_.Name -ne ".DS_Store") {
                        $r.extra.Add($eRel) | Out-Null
                    }
                }
        }

        $clean = ($r.files_ok -eq $r.files_total) -and
                 ($r.missing.Count -eq 0) -and ($r.size_mismatch.Count -eq 0) -and
                 ($r.checksum_mismatch.Count -eq 0) -and ($r.extra.Count -eq 0) -and
                 ($r.errors.Count -eq 0)
        $r.status = if ($clean) { "verified" } else { "failed" }

        $rPath = Join-Path $effectiveOut "receipt-manifest-$($r.batch_id).json"
        Write-ManifestJson $rPath ([PSCustomObject]$r)

        if (-not $Quiet) {
            $color = if ($clean) { "Green" } else { "Red" }
            Write-Host "[$($r.status.ToUpper())] $($r.batch_id): $($r.files_ok)/$($r.files_total) files ok" -ForegroundColor $color
        }
        $allReceipts.Add([PSCustomObject]$r) | Out-Null
    }

    $agg = [PSCustomObject][ordered]@{
        manifest_version = 2
        kind             = "receipt-manifest"
        scope            = "aggregate"
        verified_utc     = Get-UtcStamp
        hostname         = [System.Net.Dns]::GetHostName()
        inbox            = (Resolve-Path $Inbox).Path
        batches_total    = $allReceipts.Count
        batches_verified = @($allReceipts | Where-Object { $_.status -eq "verified" }).Count
        batches          = [array]$allReceipts
    }

    $aggPath = Join-Path $effectiveOut "receipt-manifest.json"
    Write-ManifestJson $aggPath $agg

    if (-not $Quiet) {
        Write-Host "Wrote $aggPath ($($agg.batches_verified)/$($agg.batches_total) batches verified)"
    }
    return ($agg.batches_verified -eq $agg.batches_total)
}

# ── Export ──────────────────────────────────────────────────────────────

function Invoke-Export {
    if (-not (Test-Path $CabinetRoot -PathType Container)) {
        Write-Host "ERROR: cabinet root not found: $CabinetRoot" -ForegroundColor Red
        exit 2
    }
    $effectiveOut = if ($OutDir) { $OutDir } else { (Get-Location).Path }
    Ensure-Dir $effectiveOut

    $rootFull = (Resolve-Path $CabinetRoot).Path

    $treeList     = [System.Collections.ArrayList]::new()
    $receiptsList = [System.Collections.ArrayList]::new()
    $totalFiles   = 0
    $totalBytes   = [long]0

    $dirQueue = [System.Collections.ArrayList]::new()
    $dirQueue.Add($rootFull) | Out-Null

    function Collect-Dirs([string]$parent) {
        Get-ChildItem $parent -Directory -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-Excluded $_.Name) } |
            Sort-Object Name | ForEach-Object {
                $dirQueue.Add($_.FullName) | Out-Null
                Collect-Dirs $_.FullName
            }
    }
    Collect-Dirs $rootFull

    foreach ($dirPath in $dirQueue) {
        $rel = if ($dirPath -eq $rootFull) { "." } else {
            $dirPath.Substring($rootFull.Length + 1) -replace "\\", "/"
        }

        $childDirNames = [array]@(
            Get-ChildItem $dirPath -Directory -ErrorAction SilentlyContinue |
                Where-Object { -not (Test-Excluded $_.Name) } |
                Sort-Object Name |
                ForEach-Object { $_.Name }
        )

        $dirBytes  = [long]0
        $fileCount = 0

        Get-ChildItem $dirPath -File -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-Excluded $_.Name) } |
            Sort-Object Name | ForEach-Object {
                $fileCount++
                $dirBytes += $_.Length
                if ($_.Name -like "receipt-manifest*.json") {
                    $rRel = if ($rel -eq ".") { $_.Name } else { "$rel/$($_.Name)" }
                    $receiptsList.Add([PSCustomObject][ordered]@{
                        path   = $rRel
                        size   = $_.Length
                        sha256 = Get-SHA256 $_.FullName
                    }) | Out-Null
                }
            }

        $treeList.Add([PSCustomObject][ordered]@{
            path       = $rel
            dirs       = $childDirNames
            file_count = $fileCount
            bytes      = $dirBytes
        }) | Out-Null

        $totalFiles += $fileCount
        $totalBytes += $dirBytes
    }

    $manifest = [PSCustomObject][ordered]@{
        manifest_version = 2
        kind             = "offline-structure-manifest"
        generated_utc    = Get-UtcStamp
        hostname         = [System.Net.Dns]::GetHostName()
        root             = $rootFull
        totals           = [PSCustomObject][ordered]@{
            directories = $treeList.Count
            files       = $totalFiles
            bytes       = $totalBytes
        }
        tree             = [array]$treeList
        receipts         = [array]$receiptsList
    }

    $outPath = Join-Path $effectiveOut "offline-structure-manifest.json"
    $json = $manifest | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($outPath, "$json`n", $script:Utf8NoBom)

    $hashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
        $script:Utf8NoBom.GetBytes("$json`n"))
    $digest = ($hashBytes | ForEach-Object { $_.ToString("x2") }) -join ""
    [System.IO.File]::WriteAllText("$outPath.sha256",
        "$digest  offline-structure-manifest.json`n", $script:Utf8NoBom)

    if (-not $Quiet) {
        Write-Host "Wrote $outPath ($($treeList.Count) dirs, $totalFiles files, $totalBytes bytes, $($receiptsList.Count) receipt(s))"
    }
}

# ── Place ───────────────────────────────────────────────────────────────

function Invoke-Place {
    if (-not $BatchPath) {
        Write-Host "ERROR: -BatchPath is required for place mode" -ForegroundColor Red
        exit 2
    }
    if (-not (Test-Path $BatchPath -PathType Container)) {
        Write-Host "ERROR: batch directory not found: $BatchPath" -ForegroundColor Red
        exit 2
    }
    if (-not (Test-Path $CabinetRoot -PathType Container)) {
        Write-Host "ERROR: cabinet root not found: $CabinetRoot" -ForegroundColor Red
        exit 2
    }

    $placementManifestPath = Join-Path $BatchPath "placement-manifest.json"
    if (-not (Test-Path $placementManifestPath -PathType Leaf)) {
        Write-Host "ERROR: placement-manifest.json not found in batch: $BatchPath" -ForegroundColor Red
        exit 2
    }

    try {
        $pm = Get-Content $placementManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Host "ERROR: cannot parse placement-manifest.json: $_" -ForegroundColor Red
        exit 2
    }

    $payloadRoot = Join-Path $BatchPath "payload"
    if (-not (Test-Path $payloadRoot -PathType Container)) {
        Write-Host "ERROR: payload directory not found in batch: $BatchPath" -ForegroundColor Red
        exit 2
    }

    $placements = @($pm.placements)
    if ($placements.Count -eq 0) {
        Write-Host "WARNING: no placements defined in placement-manifest.json" -ForegroundColor Yellow
    }

    $results = [System.Collections.ArrayList]::new()
    $placedCount   = 0
    $skippedCount  = 0
    $renamedCount  = 0
    $failedCount   = 0

    foreach ($entry in $placements) {
        $srcRel = $entry.source
        $destRel = $entry.destination
        $conflictPolicy = "skip"
        if ($entry.PSObject.Properties.Name -contains "conflict_policy" -and $entry.conflict_policy) {
            $conflictPolicy = $entry.conflict_policy.ToLower()
        }

        $result = [ordered]@{
            source           = $srcRel
            destination      = $destRel
            conflict_policy  = $conflictPolicy
            status           = "failed"
            final_path       = $null
            error            = $null
        }

        # Resolve source path within payload
        $srcPath = Join-Path $payloadRoot ($srcRel -replace "/", [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path $srcPath -PathType Leaf)) {
            $result.status = "failed"
            $result.error = "source file not found in payload: $srcRel"
            $failedCount++
            $results.Add([PSCustomObject]$result) | Out-Null
            if (-not $Quiet) {
                Write-Host "[FAILED] $srcRel - source not found" -ForegroundColor Red
            }
            continue
        }

        # Resolve destination relative to CabinetRoot
        $destFull = Join-Path $CabinetRoot ($destRel -replace "/", [IO.Path]::DirectorySeparatorChar)
        $destDir  = Split-Path $destFull -Parent
        $destName = Split-Path $destFull -Leaf

        # SHA-256 verify source before placement
        try {
            $srcHash = Get-SHA256 $srcPath
        } catch {
            $result.status = "failed"
            $result.error = "cannot compute SHA-256 of source: $_"
            $failedCount++
            $results.Add([PSCustomObject]$result) | Out-Null
            if (-not $Quiet) {
                Write-Host "[FAILED] $srcRel - hash computation error" -ForegroundColor Red
            }
            continue
        }

        # Verify against manifest hash if provided
        if ($entry.PSObject.Properties.Name -contains "sha256" -and $entry.sha256) {
            if ($srcHash -ne $entry.sha256.ToLower()) {
                $result.status = "failed"
                $result.error = "SHA-256 mismatch: expected $($entry.sha256), got $srcHash"
                $failedCount++
                $results.Add([PSCustomObject]$result) | Out-Null
                if (-not $Quiet) {
                    Write-Host "[FAILED] $srcRel - checksum mismatch before placement" -ForegroundColor Red
                }
                continue
            }
        }

        # Ensure destination directory exists
        try {
            Ensure-Dir $destDir
        } catch {
            $result.status = "failed"
            $result.error = "cannot create destination directory: $_"
            $failedCount++
            $results.Add([PSCustomObject]$result) | Out-Null
            if (-not $Quiet) {
                Write-Host "[FAILED] $srcRel - cannot create directory" -ForegroundColor Red
            }
            continue
        }

        # Check for conflict
        $finalDest = $destFull
        if (Test-Path $destFull -PathType Leaf) {
            switch ($conflictPolicy) {
                "skip" {
                    $result.status = "skipped"
                    $result.final_path = $destRel
                    $result.error = "file already exists at destination"
                    $skippedCount++
                    $results.Add([PSCustomObject]$result) | Out-Null
                    if (-not $Quiet) {
                        Write-Host "[SKIPPED] $srcRel -> $destRel (already exists)" -ForegroundColor Yellow
                    }
                    continue
                }
                "rename" {
                    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($destName)
                    $ext      = [System.IO.Path]::GetExtension($destName)
                    $counter  = 1
                    do {
                        $newName  = "${baseName}-${counter}${ext}"
                        $finalDest = Join-Path $destDir $newName
                        $counter++
                    } while (Test-Path $finalDest -PathType Leaf)
                    # Update destRel to reflect the renamed file
                    $destRelDir = Split-Path $destRel -Parent
                    if ($destRelDir) {
                        $destRel = Join-Path $destRelDir $newName
                        $destRel = $destRel -replace "\\", "/"
                    } else {
                        $destRel = $newName
                    }
                }
                "overwrite" {
                    # Explicit overwrite — proceed with the original destination
                }
                default {
                    # Unknown policy — treat as skip for safety
                    $result.status = "skipped"
                    $result.final_path = $destRel
                    $result.error = "unknown conflict_policy '$conflictPolicy'; defaulting to skip"
                    $skippedCount++
                    $results.Add([PSCustomObject]$result) | Out-Null
                    if (-not $Quiet) {
                        Write-Host "[SKIPPED] $srcRel -> $destRel (unknown policy)" -ForegroundColor Yellow
                    }
                    continue
                }
            }
        }

        # Perform the copy (copy, not move — source stays until receipt returns)
        try {
            Copy-Item -Path $srcPath -Destination $finalDest -Force:($conflictPolicy -eq "overwrite")
        } catch {
            $result.status = "failed"
            $result.error = "copy failed: $_"
            $failedCount++
            $results.Add([PSCustomObject]$result) | Out-Null
            if (-not $Quiet) {
                Write-Host "[FAILED] $srcRel - copy error: $_" -ForegroundColor Red
            }
            continue
        }

        # Post-copy SHA-256 verification
        try {
            $destHash = Get-SHA256 $finalDest
        } catch {
            # Copy succeeded but we cannot verify — report as failed
            try { Remove-Item $finalDest -Force -ErrorAction SilentlyContinue } catch {}
            $result.status = "failed"
            $result.error = "post-copy SHA-256 verification failed: $_"
            $failedCount++
            $results.Add([PSCustomObject]$result) | Out-Null
            if (-not $Quiet) {
                Write-Host "[FAILED] $srcRel - post-copy verification error" -ForegroundColor Red
            }
            continue
        }

        if ($destHash -ne $srcHash) {
            # Integrity failure — remove the bad copy
            try { Remove-Item $finalDest -Force -ErrorAction SilentlyContinue } catch {}
            $result.status = "failed"
            $result.error = "post-copy SHA-256 mismatch: source=$srcHash, destination=$destHash"
            $failedCount++
            $results.Add([PSCustomObject]$result) | Out-Null
            if (-not $Quiet) {
                Write-Host "[FAILED] $srcRel - post-copy checksum mismatch" -ForegroundColor Red
            }
            continue
        }

        # Determine the reported status
        $wasRenamed = ($finalDest -ne (Join-Path $CabinetRoot ($entry.destination -replace "/", [IO.Path]::DirectorySeparatorChar)))
        if ($wasRenamed) {
            $result.status = "renamed"
            $renamedCount++
        } else {
            $result.status = "placed"
            $placedCount++
        }
        $result.final_path = $destRel
        $result.sha256 = $destHash

        $results.Add([PSCustomObject]$result) | Out-Null
        if (-not $Quiet) {
            $color = if ($wasRenamed) { "Cyan" } else { "Green" }
            $label = if ($wasRenamed) { "RENAMED" } else { "PLACED" }
            Write-Host "[$label] $srcRel -> $destRel" -ForegroundColor $color
        }
    }

    # Write placement receipt
    $receipt = [PSCustomObject][ordered]@{
        manifest_version = 2
        kind             = "placement-receipt"
        batch_id         = if ($pm.PSObject.Properties.Name -contains "batch_id") { $pm.batch_id } else { (Split-Path $BatchPath -Leaf) }
        placed_utc       = Get-UtcStamp
        hostname         = [System.Net.Dns]::GetHostName()
        cabinet_root     = $CabinetRoot
        summary          = [PSCustomObject][ordered]@{
            total   = $placements.Count
            placed  = $placedCount
            skipped = $skippedCount
            renamed = $renamedCount
            failed  = $failedCount
        }
        placements       = [array]$results
    }

    $receiptPath = Join-Path $BatchPath "placement-receipt.json"
    Write-ManifestJson $receiptPath $receipt

    if (-not $Quiet) {
        Write-Host ""
        Write-Host "Placement complete: $placedCount placed, $skippedCount skipped, $renamedCount renamed, $failedCount failed" -ForegroundColor White
        Write-Host "Wrote $receiptPath"
    }

    # After placement, refresh the structure manifest
    if (-not $Quiet) {
        Write-Host ""
        Write-Host "Updating offline-structure-manifest.json..." -ForegroundColor White
    }
    Invoke-Export

    return ($failedCount -eq 0)
}

# ── Serve ───────────────────────────────────────────────────────────────

function Read-RequestBody($context) {
    $reader = [System.IO.StreamReader]::new($context.Request.InputStream, $context.Request.ContentEncoding)
    try {
        return $reader.ReadToEnd()
    } finally {
        $reader.Close()
    }
}

function Send-JsonResponse($context, $obj, [int]$statusCode = 200) {
    $json = ConvertTo-JsonSafe $obj
    $buffer = $script:Utf8NoBom.GetBytes($json)
    $context.Response.StatusCode = $statusCode
    $context.Response.ContentType = "application/json; charset=utf-8"
    $context.Response.ContentLength64 = $buffer.Length
    $context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $context.Response.OutputStream.Close()
}

function Send-ErrorResponse($context, [string]$message, [int]$statusCode = 400) {
    $obj = [PSCustomObject]@{ error = $message }
    Send-JsonResponse $context $obj $statusCode
}

function Send-HtmlResponse($context, [string]$html) {
    $buffer = $script:Utf8NoBom.GetBytes($html)
    $context.Response.StatusCode = 200
    $context.Response.ContentType = "text/html; charset=utf-8"
    $context.Response.ContentLength64 = $buffer.Length
    $context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $context.Response.OutputStream.Close()
}

function Get-CabinetTreeJson([string]$root) {
    # Returns a nested JSON tree of the Cabinet directory structure
    if (-not (Test-Path $root -PathType Container)) {
        return [PSCustomObject]@{ error = "cabinet root not found" }
    }

    function Build-TreeNode([string]$dirPath, [string]$relPath) {
        $children = [System.Collections.ArrayList]::new()
        $fileCount = 0
        $dirBytes  = [long]0

        Get-ChildItem $dirPath -File -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-Excluded $_.Name) } |
            ForEach-Object {
                $fileCount++
                $dirBytes += $_.Length
            }

        Get-ChildItem $dirPath -Directory -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-Excluded $_.Name) } |
            Sort-Object Name | ForEach-Object {
                $childRel = if ($relPath -eq ".") { $_.Name } else { "$relPath/$($_.Name)" }
                $children.Add((Build-TreeNode $_.FullName $childRel)) | Out-Null
            }

        return [PSCustomObject][ordered]@{
            name       = Split-Path $dirPath -Leaf
            path       = $relPath
            file_count = $fileCount
            bytes      = $dirBytes
            children   = [array]$children
        }
    }

    $rootNode = Build-TreeNode $root "."
    $rootNode.name = Split-Path $root -Leaf
    return $rootNode
}

function Verify-BatchJson([string]$batchDir) {
    # Read and verify a batch directory, return structured JSON result
    if (-not (Test-Path $batchDir -PathType Container)) {
        return [PSCustomObject]@{ error = "batch directory not found: $batchDir" }
    }

    $transferManifestPath = Join-Path $batchDir "transfer-manifest.json"
    $placementManifestPath = Join-Path $batchDir "placement-manifest.json"

    $result = [ordered]@{
        batch_dir          = $batchDir
        batch_id           = Split-Path $batchDir -Leaf
        has_transfer_manifest  = (Test-Path $transferManifestPath -PathType Leaf)
        has_placement_manifest = (Test-Path $placementManifestPath -PathType Leaf)
        transfer_manifest  = $null
        placement_manifest = $null
        verification       = $null
    }

    # Read transfer manifest
    if ($result.has_transfer_manifest) {
        try {
            $tm = Get-Content $transferManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $result.transfer_manifest = $tm

            # Verify files
            $payloadRoot = Join-Path $batchDir "payload"
            $verifyResults = [System.Collections.ArrayList]::new()
            $okCount = 0
            $failCount = 0

            if ($tm.files) {
                foreach ($entry in @($tm.files)) {
                    $fpath = Join-Path $payloadRoot ($entry.path -replace "/", [IO.Path]::DirectorySeparatorChar)
                    $vr = [ordered]@{
                        path   = $entry.path
                        status = "missing"
                    }
                    if (Test-Path $fpath -PathType Leaf) {
                        $fi = Get-Item $fpath
                        if ($fi.Length -ne [long]$entry.size) {
                            $vr.status = "size_mismatch"
                            $vr.expected_size = $entry.size
                            $vr.actual_size = $fi.Length
                            $failCount++
                        } else {
                            $digest = Get-SHA256 $fpath
                            if ($digest -ne $entry.sha256) {
                                $vr.status = "checksum_mismatch"
                                $vr.expected_sha256 = $entry.sha256
                                $vr.actual_sha256 = $digest
                                $failCount++
                            } else {
                                $vr.status = "ok"
                                $okCount++
                            }
                        }
                    } else {
                        $failCount++
                    }
                    $verifyResults.Add([PSCustomObject]$vr) | Out-Null
                }
            }

            $result.verification = [PSCustomObject][ordered]@{
                files_total = $verifyResults.Count
                files_ok    = $okCount
                files_fail  = $failCount
                status      = if ($failCount -eq 0 -and $okCount -gt 0) { "verified" } else { "failed" }
                files       = [array]$verifyResults
            }
        } catch {
            $result.transfer_manifest = [PSCustomObject]@{ error = "parse error: $_" }
        }
    }

    # Read placement manifest
    if ($result.has_placement_manifest) {
        try {
            $result.placement_manifest = Get-Content $placementManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            $result.placement_manifest = [PSCustomObject]@{ error = "parse error: $_" }
        }
    }

    return [PSCustomObject]$result
}

function Check-ConflictsJson([string]$batchDir) {
    # Check proposed placements against existing Cabinet files
    $placementManifestPath = Join-Path $batchDir "placement-manifest.json"
    if (-not (Test-Path $placementManifestPath -PathType Leaf)) {
        return [PSCustomObject]@{ error = "placement-manifest.json not found in $batchDir" }
    }

    try {
        $pm = Get-Content $placementManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return [PSCustomObject]@{ error = "cannot parse placement-manifest.json: $_" }
    }

    $conflicts = [System.Collections.ArrayList]::new()
    $placements = @($pm.placements)

    foreach ($entry in $placements) {
        $destFull = Join-Path $CabinetRoot ($entry.destination -replace "/", [IO.Path]::DirectorySeparatorChar)
        $has_conflict = Test-Path $destFull -PathType Leaf
        $existing_size = $null
        $existing_sha256 = $null

        if ($has_conflict) {
            try {
                $fi = Get-Item $destFull
                $existing_size = $fi.Length
                $existing_sha256 = Get-SHA256 $destFull
            } catch {
                # Silently ignore — we still report the conflict
            }
        }

        $conflicts.Add([PSCustomObject][ordered]@{
            source          = $entry.source
            destination     = $entry.destination
            has_conflict    = $has_conflict
            existing_size   = $existing_size
            existing_sha256 = $existing_sha256
        }) | Out-Null
    }

    return [PSCustomObject][ordered]@{
        batch_dir      = $batchDir
        total          = $placements.Count
        conflicts      = @($conflicts | Where-Object { $_.has_conflict }).Count
        no_conflicts   = @($conflicts | Where-Object { -not $_.has_conflict }).Count
        placements     = [array]$conflicts
    }
}

function Invoke-PlaceFromJson([string]$jsonBody) {
    # Execute placement from a JSON request body
    try {
        $request = $jsonBody | ConvertFrom-Json
    } catch {
        return [PSCustomObject]@{ error = "invalid JSON body: $_" }
    }

    $reqBatchPath = $null
    if ($request.PSObject.Properties.Name -contains "batch_path" -and $request.batch_path) {
        $reqBatchPath = $request.batch_path
    }
    if (-not $reqBatchPath) {
        return [PSCustomObject]@{ error = "batch_path is required" }
    }
    if (-not (Test-Path $reqBatchPath -PathType Container)) {
        return [PSCustomObject]@{ error = "batch directory not found: $reqBatchPath" }
    }

    $payloadRoot = Join-Path $reqBatchPath "payload"
    if (-not (Test-Path $payloadRoot -PathType Container)) {
        return [PSCustomObject]@{ error = "payload directory not found in batch" }
    }

    # Use placements from the request body, or fall back to placement-manifest.json
    $placements = $null
    if ($request.PSObject.Properties.Name -contains "placements" -and $request.placements) {
        $placements = @($request.placements)
    } else {
        $pmPath = Join-Path $reqBatchPath "placement-manifest.json"
        if (-not (Test-Path $pmPath -PathType Leaf)) {
            return [PSCustomObject]@{ error = "no placements in request and placement-manifest.json not found" }
        }
        try {
            $pm = Get-Content $pmPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $placements = @($pm.placements)
        } catch {
            return [PSCustomObject]@{ error = "cannot parse placement-manifest.json: $_" }
        }
    }

    $results = [System.Collections.ArrayList]::new()
    $placedCount  = 0
    $skippedCount = 0
    $renamedCount = 0
    $failedCount  = 0

    foreach ($entry in $placements) {
        $srcRel = $entry.source
        $destRel = $entry.destination
        $conflictPolicy = "skip"
        if ($entry.PSObject.Properties.Name -contains "conflict_policy" -and $entry.conflict_policy) {
            $conflictPolicy = $entry.conflict_policy.ToLower()
        }

        $result = [ordered]@{
            source          = $srcRel
            destination     = $destRel
            conflict_policy = $conflictPolicy
            status          = "failed"
            final_path      = $null
            error           = $null
        }

        $srcPath = Join-Path $payloadRoot ($srcRel -replace "/", [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path $srcPath -PathType Leaf)) {
            $result.error = "source file not found in payload"
            $failedCount++
            $results.Add([PSCustomObject]$result) | Out-Null
            continue
        }

        $destFull = Join-Path $CabinetRoot ($destRel -replace "/", [IO.Path]::DirectorySeparatorChar)
        $destDir  = Split-Path $destFull -Parent
        $destName = Split-Path $destFull -Leaf

        # SHA-256 of source
        try {
            $srcHash = Get-SHA256 $srcPath
        } catch {
            $result.error = "cannot compute SHA-256 of source: $_"
            $failedCount++
            $results.Add([PSCustomObject]$result) | Out-Null
            continue
        }

        if ($entry.PSObject.Properties.Name -contains "sha256" -and $entry.sha256) {
            if ($srcHash -ne $entry.sha256.ToLower()) {
                $result.error = "SHA-256 mismatch: expected $($entry.sha256), got $srcHash"
                $result.status = "failed"
                $failedCount++
                $results.Add([PSCustomObject]$result) | Out-Null
                continue
            }
        }

        try { Ensure-Dir $destDir } catch {
            $result.error = "cannot create destination directory: $_"
            $failedCount++
            $results.Add([PSCustomObject]$result) | Out-Null
            continue
        }

        $finalDest = $destFull
        $finalDestRel = $destRel
        if (Test-Path $destFull -PathType Leaf) {
            switch ($conflictPolicy) {
                "skip" {
                    $result.status = "skipped"
                    $result.final_path = $destRel
                    $result.error = "file already exists at destination"
                    $skippedCount++
                    $results.Add([PSCustomObject]$result) | Out-Null
                    continue
                }
                "rename" {
                    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($destName)
                    $ext      = [System.IO.Path]::GetExtension($destName)
                    $counter  = 1
                    do {
                        $newName   = "${baseName}-${counter}${ext}"
                        $finalDest = Join-Path $destDir $newName
                        $counter++
                    } while (Test-Path $finalDest -PathType Leaf)
                    $destRelDir = Split-Path $destRel -Parent
                    if ($destRelDir) {
                        $finalDestRel = (Join-Path $destRelDir $newName) -replace "\\", "/"
                    } else {
                        $finalDestRel = $newName
                    }
                }
                "overwrite" {
                    # Explicit overwrite
                }
                default {
                    $result.status = "skipped"
                    $result.final_path = $destRel
                    $result.error = "unknown conflict_policy '$conflictPolicy'; defaulting to skip"
                    $skippedCount++
                    $results.Add([PSCustomObject]$result) | Out-Null
                    continue
                }
            }
        }

        try {
            Copy-Item -Path $srcPath -Destination $finalDest -Force:($conflictPolicy -eq "overwrite")
        } catch {
            $result.error = "copy failed: $_"
            $failedCount++
            $results.Add([PSCustomObject]$result) | Out-Null
            continue
        }

        try {
            $destHash = Get-SHA256 $finalDest
        } catch {
            try { Remove-Item $finalDest -Force -ErrorAction SilentlyContinue } catch {}
            $result.error = "post-copy SHA-256 verification failed: $_"
            $failedCount++
            $results.Add([PSCustomObject]$result) | Out-Null
            continue
        }

        if ($destHash -ne $srcHash) {
            try { Remove-Item $finalDest -Force -ErrorAction SilentlyContinue } catch {}
            $result.error = "post-copy SHA-256 mismatch"
            $failedCount++
            $results.Add([PSCustomObject]$result) | Out-Null
            continue
        }

        $wasRenamed = ($finalDest -ne (Join-Path $CabinetRoot ($entry.destination -replace "/", [IO.Path]::DirectorySeparatorChar)))
        $result.status = if ($wasRenamed) { "renamed" } else { "placed" }
        $result.final_path = $finalDestRel
        $result.sha256 = $destHash

        if ($wasRenamed) { $renamedCount++ } else { $placedCount++ }
        $results.Add([PSCustomObject]$result) | Out-Null
    }

    # Write placement receipt to the batch directory
    $batchId = if ($request.PSObject.Properties.Name -contains "batch_id") { $request.batch_id } else { Split-Path $reqBatchPath -Leaf }
    $receipt = [PSCustomObject][ordered]@{
        manifest_version = 2
        kind             = "placement-receipt"
        batch_id         = $batchId
        placed_utc       = Get-UtcStamp
        hostname         = [System.Net.Dns]::GetHostName()
        cabinet_root     = $CabinetRoot
        summary          = [PSCustomObject][ordered]@{
            total   = $placements.Count
            placed  = $placedCount
            skipped = $skippedCount
            renamed = $renamedCount
            failed  = $failedCount
        }
        placements       = [array]$results
    }

    $receiptPath = Join-Path $reqBatchPath "placement-receipt.json"
    Write-ManifestJson $receiptPath $receipt

    return $receipt
}

function Invoke-Serve {
    Add-Type -AssemblyName System.Web

    $cabinetReady = Test-Path $CabinetRoot -PathType Container
    if (-not $cabinetReady) {
        Write-Host "WARNING: cabinet root not found: $CabinetRoot" -ForegroundColor Yellow
        Write-Host "The server will start, but file operations need a valid cabinet root." -ForegroundColor Yellow
        Write-Host "Configure it through the web UI or update transfer-gate.json." -ForegroundColor Yellow
        Write-Host ""
    }

    $prefix = "http://localhost:${Port}/"
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($prefix)

    try {
        $listener.Start()
    } catch {
        Write-Host "ERROR: cannot start HTTP listener on $prefix" -ForegroundColor Red
        Write-Host "Detail: $_" -ForegroundColor Red
        Write-Host ""
        Write-Host "Common causes:" -ForegroundColor Yellow
        Write-Host "  - Port $Port is already in use by another application" -ForegroundColor Yellow
        Write-Host "  - Try a different port: powershell -File transfer-gate.ps1 -Mode serve -Port 9090" -ForegroundColor Yellow
        exit 2
    }

    Write-Host "Transfer Gate v$($script:Version) server running at $prefix" -ForegroundColor Green
    if ($cabinetReady) {
        Write-Host "Cabinet root: $CabinetRoot" -ForegroundColor White
    } else {
        Write-Host "Cabinet root: NOT CONFIGURED — open the UI to set it" -ForegroundColor Yellow
    }
    Write-Host "Press Ctrl+C to stop." -ForegroundColor Gray
    Write-Host ""

    $htmlPath = Join-Path $PSScriptRoot "transfer-gate.html"

    try {
        while ($listener.IsListening) {
            $context = $null
            try {
                $context = $listener.GetContext()
            } catch [System.Net.HttpListenerException] {
                # Listener was stopped (e.g., Ctrl+C)
                break
            }

            $method  = $context.Request.HttpMethod
            $rawUrl  = $context.Request.RawUrl
            # Strip query string for routing
            $urlPath = ($rawUrl -split "\?")[0]

            if (-not $Quiet) {
                Write-Host "$(Get-Date -Format 'HH:mm:ss') $method $rawUrl" -ForegroundColor Gray
            }

            try {
                # ── GET / ─────────────────────────────────────────────
                if ($method -eq "GET" -and ($urlPath -eq "/" -or $urlPath -eq "/index.html")) {
                    if (Test-Path $htmlPath -PathType Leaf) {
                        $html = [System.IO.File]::ReadAllText($htmlPath, $script:Utf8NoBom)
                        Send-HtmlResponse $context $html
                    } else {
                        Send-ErrorResponse $context "transfer-gate.html not found in script directory" 404
                    }
                }

                # ── GET /api/health ────────────────────────────────────
                elseif ($method -eq "GET" -and $urlPath -eq "/api/health") {
                    Send-JsonResponse $context ([PSCustomObject]@{
                        status  = "ok"
                        version = $script:Version
                    })
                }

                # ── GET /api/config ────────────────────────────────────
                elseif ($method -eq "GET" -and $urlPath -eq "/api/config") {
                    $sourcePath = if ($cfg.PSObject.Properties.Name -contains "sourcePath") { $cfg.sourcePath } else { "" }
                    $sortedPath = if ($cfg.PSObject.Properties.Name -contains "sortedPath") { $cfg.sortedPath } else { "" }
                    Send-JsonResponse $context ([PSCustomObject][ordered]@{
                        sourcePath     = $sourcePath
                        sortedPath     = $sortedPath
                        cabinetRoot    = $CabinetRoot
                        cabinetReady   = (Test-Path $CabinetRoot -PathType Container)
                        inbox          = $Inbox
                        manifestOutput = $OutDir
                        exclude        = @($cfg.exclude)
                    })
                }

                # ── PUT /api/config ────────────────────────────────────
                elseif ($method -eq "PUT" -and $urlPath -eq "/api/config") {
                    $body = Read-RequestBody $context
                    try {
                        $update = $body | ConvertFrom-Json
                    } catch {
                        Send-ErrorResponse $context "invalid JSON body"
                        continue
                    }
                    if ($update.PSObject.Properties.Name -contains "sourcePath") {
                        $cfg | Add-Member -NotePropertyName sourcePath -NotePropertyValue $update.sourcePath -Force
                    }
                    if ($update.PSObject.Properties.Name -contains "sortedPath") {
                        $cfg | Add-Member -NotePropertyName sortedPath -NotePropertyValue $update.sortedPath -Force
                    }
                    if ($update.PSObject.Properties.Name -contains "cabinetRoot" -and $update.cabinetRoot) {
                        $newRoot = $update.cabinetRoot
                        if (-not (Test-Path $newRoot -PathType Container)) {
                            Send-ErrorResponse $context "cabinet root not found: $newRoot" 404
                            continue
                        }
                        $script:CabinetRoot = $newRoot
                        $script:Inbox  = Resolve-ConfigPath $cfg.inbox $script:CabinetRoot
                        $script:OutDir = Resolve-ConfigPath $cfg.manifestOutput $script:CabinetRoot
                    }
                    $sourcePath = if ($cfg.PSObject.Properties.Name -contains "sourcePath") { $cfg.sourcePath } else { "" }
                    $sortedPath = if ($cfg.PSObject.Properties.Name -contains "sortedPath") { $cfg.sortedPath } else { "" }
                    Send-JsonResponse $context ([PSCustomObject][ordered]@{
                        sourcePath     = $sourcePath
                        sortedPath     = $sortedPath
                        cabinetRoot    = $CabinetRoot
                        inbox          = $Inbox
                        manifestOutput = $OutDir
                        message        = "config updated for this session"
                    })
                }

                # ── GET /api/tree ──────────────────────────────────────
                elseif ($method -eq "GET" -and $urlPath -eq "/api/tree") {
                    if (-not (Test-Path $CabinetRoot -PathType Container)) {
                        Send-ErrorResponse $context "cabinet root not found: $CabinetRoot — update cabinetRoot via PUT /api/config" 404
                    } else {
                        $tree = Get-CabinetTreeJson $CabinetRoot
                        Send-JsonResponse $context $tree
                    }
                }

                # ── GET /api/batch?path=<dir> ──────────────────────────
                elseif ($method -eq "GET" -and $urlPath -eq "/api/batch") {
                    $qs = [System.Web.HttpUtility]::ParseQueryString($context.Request.Url.Query)
                    $batchDir = $qs["path"]
                    if (-not $batchDir) {
                        Send-ErrorResponse $context "query parameter 'path' is required"
                        continue
                    }
                    $batchResult = Verify-BatchJson $batchDir
                    Send-JsonResponse $context $batchResult
                }

                # ── GET /api/conflicts?path=<dir> ──────────────────────
                elseif ($method -eq "GET" -and $urlPath -eq "/api/conflicts") {
                    $qs = [System.Web.HttpUtility]::ParseQueryString($context.Request.Url.Query)
                    $batchDir = $qs["path"]
                    if (-not $batchDir) {
                        Send-ErrorResponse $context "query parameter 'path' is required"
                        continue
                    }
                    $conflictResult = Check-ConflictsJson $batchDir
                    Send-JsonResponse $context $conflictResult
                }

                # ── POST /api/place ────────────────────────────────────
                elseif ($method -eq "POST" -and $urlPath -eq "/api/place") {
                    $body = Read-RequestBody $context
                    $placeResult = Invoke-PlaceFromJson $body
                    $statusCode = 200
                    if ($placeResult.PSObject.Properties.Name -contains "error") {
                        $statusCode = 400
                    }
                    Send-JsonResponse $context $placeResult $statusCode
                }

                # ── 404 ───────────────────────────────────────────────
                else {
                    Send-ErrorResponse $context "not found: $method $urlPath" 404
                }
            } catch {
                try {
                    Send-ErrorResponse $context "internal server error: $_" 500
                } catch {
                    # Response stream may already be closed
                }
                if (-not $Quiet) {
                    Write-Host "ERROR handling $method $urlPath : $_" -ForegroundColor Red
                }
            }
        }
    } finally {
        $listener.Stop()
        $listener.Close()
        Write-Host "Server stopped." -ForegroundColor Yellow
    }
}

# ── Main ────────────────────────────────────────────────────────────────

$exitCode = 0
switch ($Mode) {
    "verify" { if (-not (Invoke-Verify)) { $exitCode = 1 } }
    "export" { Invoke-Export }
    "place"  { if (-not (Invoke-Place))  { $exitCode = 1 } }
    "serve"  { Invoke-Serve }
    "all"    { if (-not (Invoke-Verify)) { $exitCode = 1 }; Invoke-Export }
}
exit $exitCode
