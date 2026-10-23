<#
.SYNOPSIS
    Resumable adb push of the next pending batch to an Android phone
    (Windows port of push_next.sh).

.DESCRIPTION
    Pushes every file of a batch (see build_batches.py) into one flat folder on
    the phone, then clears Android's is_pending flag so Google Photos can see
    the files. Safe to re-run any time: already-pushed files are skipped, and a
    batch is only marked "done" in manifest.csv once every file is pushed AND
    visible to Google Photos.

    Failures are listed by filename at the end of a run, and kept next to this
    script in:
      batch_NNN.push_failed    files that failed to push
      batch_NNN.still_pending  files still hidden from Google Photos

.PARAMETER Batch
    Force a specific batch, e.g. batch_005. Default: the first batch not
    marked done in manifest.csv.

.EXAMPLE
    .\push_next.ps1

.EXAMPLE
    .\push_next.ps1 batch_005

.NOTES
    Env override: GPHOTOS_UPLOAD_DIR (default /sdcard/Pictures/GPhotosUpload).
    Works in Windows PowerShell 5.1 and PowerShell 7+.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Batch = ''
)

$ErrorActionPreference = 'Continue'
# adb prints UTF-8; without this, emoji album names come back garbled.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$IsWin = [System.IO.Path]::DirectorySeparatorChar -eq '\'

$Dir = $PSScriptRoot
$Manifest = Join-Path $Dir 'manifest.csv'
$RootFile = Join-Path $Dir 'ROOT.txt'
if ($env:GPHOTOS_UPLOAD_DIR) { $Dest = $env:GPHOTOS_UPLOAD_DIR.TrimEnd('/') } else { $Dest = '/sdcard/Pictures/GPhotosUpload' }
$DestName = ($Dest -split '/')[-1]
$DeviceHelper = '/data/local/tmp/takeout_phoenix_helper.sh'
$DeviceIds = '/data/local/tmp/takeout_phoenix_pending_ids.txt'

# Device-side helper, run by the phone's own sh. Keeping the quoted MediaStore
# commands on the device means PowerShell never passes embedded quotes through
# `adb shell` (Windows PowerShell 5.1 mangles those).
#   sh helper.sh list FOLDER   MediaStore rows under FOLDER still is_pending=1
#   sh helper.sh clear IDFILE  clear is_pending per id, print "OK id" / "FAIL id"
$HelperScript = @'
case "$1" in
  list)
    content query --uri content://media/external/file --projection _id:_data --where "_data LIKE '%$2/%' AND is_pending=1"
    ;;
  clear)
    for id in $(cat "$2"); do
      out=$(content update --uri content://media/external/file/$id --bind is_pending:i:0 2>&1)
      if [ -z "$out" ]; then echo "OK $id"; else echo "FAIL $id"; fi
    done
    rm -f "$2"
    ;;
esac
'@

# ---- helpers ----------------------------------------------------------------

function Write-Line([string]$Text = '') { [Console]::WriteLine($Text) }

function Invoke-Adb {
    # Runs adb with the given arguments; stdout goes down the pipeline as it
    # arrives, $LASTEXITCODE is adb's exit code.
    & adb @args 2>$null
}

function Get-IoPath([string]$Path) {
    # Windows PowerShell 5.1's .NET only accepts paths over 260 chars with the
    # \\?\ prefix.
    if (-not $IsWin -or $Path.Length -lt 240 -or $Path.StartsWith('\\?\')) { return $Path }
    if ($Path.StartsWith('\\')) { return '\\?\UNC\' + $Path.Substring(2) }
    return '\\?\' + $Path
}

function Add-Line([string]$Path, [string]$Text) {
    [System.IO.File]::AppendAllText($Path, $Text + "`n", $Utf8NoBom)
}

function Get-Leaf([string]$Path) {
    return $Path.Substring($Path.Replace('\', '/').LastIndexOf('/') + 1)
}

function Format-Duration([double]$Seconds) {
    $s = [int][math]::Floor($Seconds)
    return '{0}m{1:00}s' -f [int][math]::Floor($s / 60), ($s % 60)
}

function Show-Progress([int]$Current, [int]$Total, [string]$Label, [datetime]$Start, [string]$Detail) {
    $width = 30
    if ($Total -le 0) { $Total = 1 }
    $percent = [int][math]::Min(100, [math]::Floor($Current * 100 / $Total))
    $filled = [int][math]::Floor($width * $percent / 100)
    $bar = ('#' * $filled) + (' ' * ($width - $filled))
    $elapsed = ((Get-Date) - $Start).TotalSeconds
    $rate = '--'
    $eta = '--'
    if ($elapsed -ge 1 -and $Current -gt 0) {
        $rate = ($Current / $elapsed).ToString('0.0', $Invariant)
        $eta = Format-Duration (($Total - $Current) * $elapsed / $Current)
    }
    $head = '{0,-9} [{1}] {2}/{3} ({4,3}%) | {5}/s | elapsed {6} | ETA {7} | ' -f `
        $Label, $bar, $Current, $Total, $percent, $rate, (Format-Duration $elapsed), $eta
    # Fit the detail into what's left of the console line so it never wraps
    # (a wrapped line breaks the `r redraw). Never split an emoji in half.
    $max = 36
    try {
        $cols = [Console]::WindowWidth
        if ($cols -gt 0) { $max = [math]::Max(0, [math]::Min(60, $cols - 1 - $head.Length)) }
    } catch { $max = 36 } # no console (output redirected)
    if ($Detail.Length -gt $max) {
        if ($max -lt 8) {
            $Detail = ''
        } else {
            $cut = $Detail.Length - ($max - 3)
            if ([char]::IsLowSurrogate($Detail[$cut])) { $cut++ }
            $Detail = '...' + $Detail.Substring($cut)
        }
    }
    [Console]::Write("`r" + $head + $Detail.PadRight($max))
}

function Get-PendingRows {
    # MediaStore rows under $Dest still is_pending=1, as objects (Id, Path).
    # Only "Row:" lines count -- `content query` prints "No result found."
    # when nothing matches.
    foreach ($line in @(Invoke-Adb shell sh $DeviceHelper list "'$DestName'")) {
        $l = ([string]$line).TrimEnd("`r")
        if ($l -match '^Row: \d+ _id=(\d+), _data=(.*)$') {
            New-Object psobject -Property @{ Id = $Matches[1]; Path = $Matches[2] }
        }
    }
}

function Show-FileList([string]$Path, [string]$Title) {
    $max = 50
    $lines = @([System.IO.File]::ReadAllLines($Path, $Utf8NoBom) | Where-Object { $_ -ne '' })
    Write-Line $Title
    foreach ($l in ($lines | Select-Object -First $max)) { Write-Line ('  - ' + (Get-Leaf $l)) }
    if ($lines.Count -gt $max) { Write-Line ('  ... and {0} more' -f ($lines.Count - $max)) }
    Write-Line "  (full list: $Path)"
}

# ---- preflight ------------------------------------------------------------------

if (-not (Get-Command adb -ErrorAction SilentlyContinue)) {
    Write-Line 'ERROR: adb not found. Run setup-windows.ps1, or: winget install --id Google.PlatformTools -e'
    Write-Line '       (then open a new PowerShell window so PATH is refreshed)'
    exit 1
}

$null = Invoke-Adb get-state
if ($LASTEXITCODE -ne 0) {
    Write-Line 'ERROR: no phone detected over adb. Check the USB cable and the USB debugging prompt on the phone.'
    Write-Line '       Run "adb devices": empty list = install your phone''s USB driver; "unauthorized" = tap Allow.'
    exit 1
}

foreach ($f in @($Manifest, $RootFile)) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Line "ERROR: $f not found. Run build_batches.py first."
        exit 1
    }
}

$Root = [System.IO.File]::ReadAllText($RootFile, $Utf8NoBom).TrimEnd([char[]]"`r`n")

# Pick batch: argument, or the first one not marked done in the manifest.
if (-not $Batch) {
    foreach ($l in @([System.IO.File]::ReadAllLines($Manifest, $Utf8NoBom) | Select-Object -Skip 1)) {
        $fields = $l.Split(',')
        if ($fields.Count -ge 4 -and $fields[0].Trim() -and $fields[3].Trim() -ne 'done') {
            $Batch = $fields[0].Trim()
            break
        }
    }
}
if (-not $Batch) {
    Write-Line 'All batches are marked done in manifest.csv. Nothing to push.'
    exit 0
}

$BatchFile = Join-Path $Dir "$Batch.txt"
$ProgressFile = Join-Path $Dir "$Batch.progress"
$PushFailedFile = Join-Path $Dir "$Batch.push_failed"
$StillPendingFile = Join-Path $Dir "$Batch.still_pending"

if (-not (Test-Path -LiteralPath $BatchFile)) {
    Write-Line "ERROR: $BatchFile not found."
    exit 1
}

# Install the device-side helper (LF line endings, whatever git did to this file).
$helperLocal = Join-Path ([System.IO.Path]::GetTempPath()) 'takeout_phoenix_helper.sh'
[System.IO.File]::WriteAllText($helperLocal, $HelperScript.Replace("`r`n", "`n"), $Utf8NoBom)
$null = Invoke-Adb push $helperLocal $DeviceHelper
$helperOk = ($LASTEXITCODE -eq 0)
Remove-Item -LiteralPath $helperLocal -Force -ErrorAction SilentlyContinue
if (-not $helperOk) {
    Write-Line "ERROR: could not copy the helper script to the phone ($DeviceHelper)."
    exit 1
}

# ---- push -----------------------------------------------------------------------

$pushed = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
if (Test-Path -LiteralPath $ProgressFile) {
    foreach ($l in [System.IO.File]::ReadAllLines($ProgressFile, $Utf8NoBom)) { if ($l) { [void]$pushed.Add($l) } }
} else {
    [System.IO.File]::WriteAllText($ProgressFile, '', $Utf8NoBom)
}
[System.IO.File]::WriteAllText($PushFailedFile, '', $Utf8NoBom)

$batchLines = @([System.IO.File]::ReadAllLines($BatchFile, $Utf8NoBom) | Where-Object { $_ -ne '' })
$total = $batchLines.Count
$doneCount = @($batchLines | Where-Object { $pushed.Contains($_) }).Count
Write-Line "=== ${Batch}: $doneCount/$total files already pushed, resuming ==="
Write-Line "Destination on phone: $Dest"

$pushedThisRun = 0
$failed = 0
$pushStart = Get-Date
$sep = [System.IO.Path]::DirectorySeparatorChar

foreach ($rel in $batchLines) {
    if ($pushed.Contains($rel)) { continue }

    $src = [System.IO.Path]::Combine($Root, $rel.Replace('/', $sep))
    # Flatten: Google Photos' "back up device folders" doesn't recurse into
    # subfolders, so everything goes straight into $Dest with the original
    # path baked into the filename (keeps names unique, keeps origin visible).
    $flat = $rel.Replace('\', '/').Replace('/', '__')
    $dst = "$Dest/$flat"
    $srcIo = Get-IoPath $src

    if (-not [System.IO.File]::Exists($srcIo)) {
        Write-Line ''
        Write-Line "  MISSING SOURCE, skipping: $rel"
        Add-Line $PushFailedFile $rel
        continue
    }

    $pushFrom = $src
    $tempCopy = $null
    if ($IsWin -and $src.Length -ge 240) {
        # adb.exe can't open paths past Windows' classic 260-char limit, so
        # push a short temporary copy instead.
        $tempCopy = Join-Path ([System.IO.Path]::GetTempPath()) ('takeout_phoenix_push' + [System.IO.Path]::GetExtension($src))
        [System.IO.File]::Copy($srcIo, $tempCopy, $true)
        $pushFrom = $tempCopy
    }

    $null = Invoke-Adb push $pushFrom $dst
    $ok = ($LASTEXITCODE -eq 0)
    if ($tempCopy) { Remove-Item -LiteralPath $tempCopy -Force -ErrorAction SilentlyContinue }

    if ($ok) {
        Add-Line $ProgressFile $rel
        $pushedThisRun++
        $doneCount++
        Show-Progress $doneCount $total 'Push' $pushStart (Get-Leaf $rel)
    } else {
        Write-Line ''
        Write-Line "  FAILED (will retry next run): $rel"
        Add-Line $PushFailedFile $rel
        $failed++
    }
}
Write-Line ''

# ---- clear is_pending ---------------------------------------------------------------
# adb push leaves files marked is_pending=1 in MediaStore (writes via the
# shell's identity never get finalized), which hides them from every app,
# including Google Photos' backup scanner. Clear the flag on everything under
# $Dest so newly pushed files actually get picked up. Each clear forks a
# process on the phone -- that, not USB, is why this phase is slow.

$pending = @(Get-PendingRows)
if ($pending.Count -gt 0) {
    Write-Line ('Clearing is_pending on {0} file(s) so Google Photos can see them...' -f $pending.Count)
    $nameById = @{}
    foreach ($r in $pending) { $nameById[$r.Id] = Get-Leaf $r.Path }

    $idsLocal = Join-Path ([System.IO.Path]::GetTempPath()) 'takeout_phoenix_pending_ids.txt'
    [System.IO.File]::WriteAllText($idsLocal, ((@($pending | ForEach-Object { $_.Id }) -join "`n") + "`n"), $Utf8NoBom)
    $null = Invoke-Adb push $idsLocal $DeviceIds
    Remove-Item -LiteralPath $idsLocal -Force -ErrorAction SilentlyContinue

    $clearStart = Get-Date
    $cleared = 0
    $clearFailed = 0
    Invoke-Adb shell sh $DeviceHelper clear $DeviceIds | ForEach-Object {
        $l = ([string]$_).TrimEnd("`r")
        if ($l -match '^(OK|FAIL) (\d+)$') {
            $status = $Matches[1]
            $name = $nameById[$Matches[2]]
            if (-not $name) { $name = 'id ' + $Matches[2] }
            if ($status -eq 'OK') {
                $cleared++
            } else {
                $clearFailed++
                Write-Line ''
                Write-Line "  CLEAR FAILED: $name"
            }
            Show-Progress ($cleared + $clearFailed) $pending.Count 'Clear' $clearStart $name
        }
    }
    Write-Line ''
    Write-Line ('Cleared is_pending on {0}/{1} file(s) ({2} failed).' -f $cleared, $pending.Count, $clearFailed)
}

$pushedTotal = $doneCount
Write-Line ''
Write-Line "=== ${Batch}: $pushedTotal/$total files pushed total (this run: $pushedThisRun, failed: $failed) ==="

# Re-check live state rather than trusting that the clearing loop above ran
# to completion -- a cable drop mid-clearing must not get marked done, or the
# leftover pending files would be silently skipped forever.
$stillPending = @(Get-PendingRows)
[System.IO.File]::WriteAllText($StillPendingFile, (@($stillPending | ForEach-Object { $_.Path + "`n" }) -join ''), $Utf8NoBom)

if ((Get-Item -LiteralPath $PushFailedFile).Length -gt 0) {
    Show-FileList $PushFailedFile 'Failed to push:'
} else {
    Remove-Item -LiteralPath $PushFailedFile -Force
}
if ($stillPending.Count -gt 0) {
    Show-FileList $StillPendingFile 'Still hidden from Google Photos (is_pending=1):'
} else {
    Remove-Item -LiteralPath $StillPendingFile -Force
}

if ($pushedTotal -ge $total -and $stillPending.Count -eq 0) {
    $out = foreach ($l in [System.IO.File]::ReadAllLines($Manifest, $Utf8NoBom)) {
        $fields = $l.TrimEnd("`r").Split(',')
        if ($fields.Count -ge 4 -and $fields[0].Trim() -eq $Batch) {
            $fields[3] = 'done'
            ($fields | ForEach-Object { $_.Trim() }) -join ','
        } else {
            $l.TrimEnd("`r")
        }
    }
    [System.IO.File]::WriteAllText("$Manifest.tmp", (($out -join "`n") + "`n"), $Utf8NoBom)
    Move-Item -LiteralPath "$Manifest.tmp" -Destination $Manifest -Force
    Write-Line "$Batch marked DONE in manifest.csv."
    Write-Line 'Next step: on the phone, let Google Photos finish backing this batch up,'
    Write-Line "then use Google Photos > 'Free up space' to clear it, then run this script again."
} elseif ($pushedTotal -ge $total) {
    Write-Line ('{0} fully pushed, but {1} file(s) above are still marked is_pending' -f $Batch, $stillPending.Count)
    Write-Line '(clearing was likely interrupted, e.g. a cable disconnect). NOT marking done.'
    Write-Line ".\push_next.ps1 $Batch  -- re-run to finish clearing before moving to the next batch."
} else {
    Write-Line ('{0} not yet complete ({1} remaining). Re-run this script to continue.' -f $Batch, ($total - $pushedTotal))
}
