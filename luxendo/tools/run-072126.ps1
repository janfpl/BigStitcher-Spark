<#
.SYNOPSIS
    Hard-coded launcher for the BigStitcher-Spark Luxendo pipeline, wired to
    C:\Users\Admin\Documents\Jan\072126 using the Fiji installation inside that folder.

.DESCRIPTION
    This is a thin, machine-specific launcher. It does NOT modify any of the shared
    wrappers (run_pipeline.ps1, bigstitcher-spark.ps1, export-n5-bigtiff.ps1, the
    classic wrappers). It only:

      1. Bakes in the base working folder and the Fiji location for this machine.
      2. Bridges the Fiji that lives inside the base folder to the fixed location the
         unchanged wrappers expect (<this-tools-folder>\fiji\Fiji.app) via a directory
         junction, so every wrapper resolves the bundled JDK without being edited.
      3. Pre-flights Fiji / BigStitcher-Spark / dataset / Python and reports what is
         still missing, then launches run_pipeline.ps1 once everything is present.

    Any extra arguments are passed straight through to run_pipeline.ps1, e.g.:

        .\run-072126.ps1 -SeparateViews -ExportBigTiff
        .\run-072126.ps1 -RegistrationMode INTERESTPOINTS -IpMinIntensity -32768 -IpMaxIntensity 32767

.NOTES
    Place this script in the same folder as the other luxendo\tools wrappers (it calls
    run_pipeline.ps1 as a sibling). The junction it creates lives under tools\fiji\,
    which is git-ignored, so running this never dirties the repository.
#>

# Any arguments passed to this launcher are forwarded verbatim to run_pipeline.ps1
# through the automatic $args array (e.g. -SeparateViews -ExportBigTiff). A paramless
# script is used deliberately so switch-style pass-through args are not rejected.

$ErrorActionPreference = "Stop"

# ============================================================================
#  Baked-in configuration for THIS machine. Edit these two lines if paths move.
# ============================================================================

# Base working folder for this run (holds the Fiji install now; the dataset later).
$BaseDir = 'C:\Users\Admin\Documents\Jan\072126'

# Fiji location, baked in. Default assumes Fiji.app sits directly inside $BaseDir.
# If your Fiji.app is at a different spot inside the folder, set the full path here.
# If this exact path is absent, the launcher searches $BaseDir for a Fiji.app that
# has a bundled JDK.
$FijiAppDir = Join-Path $BaseDir 'Fiji.app'

# ============================================================================

$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Test-FijiApp([string] $app) {
    if (-not $app -or -not (Test-Path -LiteralPath $app)) { return $false }
    $jdk = Get-ChildItem -Directory (Join-Path $app 'java\win64') -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*jdk*' } |
        Select-Object -First 1
    return [bool]($jdk -and (Test-Path -LiteralPath (Join-Path $jdk.FullName 'bin\java.exe')))
}

if (-not (Test-Path -LiteralPath $BaseDir)) {
    throw "Base folder does not exist: $BaseDir"
}

# --- Resolve the Fiji install inside the base folder ------------------------
if (-not (Test-FijiApp $FijiAppDir)) {
    Write-Host "Fiji not found at baked-in path '$FijiAppDir'; searching under $BaseDir ..."
    $found = Get-ChildItem -Path $BaseDir -Recurse -Directory -Filter 'Fiji.app' -Depth 3 -ErrorAction SilentlyContinue |
        Where-Object { Test-FijiApp $_.FullName } |
        Select-Object -First 1
    if ($found) { $FijiAppDir = $found.FullName }
}
if (-not (Test-FijiApp $FijiAppDir)) {
    throw ("Could not find a Fiji install with a bundled JDK inside $BaseDir. " +
        "Edit `$FijiAppDir at the top of this script to point at your Fiji.app " +
        "(the folder that contains java\win64\*jdk*\bin\java.exe).")
}
Write-Host "Fiji:              $FijiAppDir"

# --- Bridge Fiji into the layout the unchanged wrappers expect --------------
# Wrappers look for <toolsDir>\fiji\Fiji.app\java\win64\*jdk*. If the real Fiji is
# somewhere else inside the base folder, link it in with a directory junction.
$expectedFiji = Join-Path $toolsDir 'fiji\Fiji.app'
if (Test-FijiApp $expectedFiji) {
    Write-Host "Wrapper Fiji path: $expectedFiji (already valid)"
} else {
    if (Test-Path -LiteralPath $expectedFiji) {
        # Only clear it if it is a reparse point (a junction/symlink we made before).
        # Never recurse-delete a real folder's contents through a link.
        $existing = Get-Item -LiteralPath $expectedFiji -Force
        if ($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            [System.IO.Directory]::Delete($expectedFiji, $false)
        } else {
            throw ("A real (non-link) folder already exists at '$expectedFiji' but has no " +
                "bundled JDK. Move it aside and re-run, or point `$FijiAppDir at the right Fiji.app.")
        }
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $expectedFiji) | Out-Null
    try {
        New-Item -ItemType Junction -Path $expectedFiji -Target $FijiAppDir | Out-Null
        Write-Host "Wrapper Fiji path: $expectedFiji  ->  $FijiAppDir (linked)"
    } catch {
        throw ("Could not link Fiji into '$expectedFiji'. Create a junction once from an " +
            "elevated prompt:`n  cmd /c mklink /J `"$expectedFiji`" `"$FijiAppDir`"`n" +
            "or copy your Fiji.app there. Underlying error: $($_.Exception.Message)")
    }
}

# --- Pre-flight: what is present vs. still missing --------------------------
$sparkJar = Join-Path $toolsDir 'BigStitcher-Spark\target\BigStitcher-Spark-0.1.0-SNAPSHOT.jar'
$hasSpark = Test-Path -LiteralPath $sparkJar

# Dataset: bdv.xml directly in the base folder, or up to 3 levels below it.
$bdv = if (Test-Path -LiteralPath (Join-Path $BaseDir 'bdv.xml')) {
    Join-Path $BaseDir 'bdv.xml'
} else {
    Get-ChildItem -Path $BaseDir -Recurse -File -Filter 'bdv.xml' -Depth 3 -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
}
$hasData = [bool]$bdv

$pythonCmd = Get-Command python -ErrorAction SilentlyContinue
$hasPython = [bool]$pythonCmd

function Show-Check([string] $label, [bool] $ok, [string] $detail) {
    $mark = if ($ok) { '[ OK ]' } else { '[MISS]' }
    Write-Host ("  {0} {1,-20} {2}" -f $mark, $label, $detail)
}

Write-Host ""
Write-Host "Pre-flight for $BaseDir :"
Show-Check "Fiji (JDK)"        $true      $FijiAppDir
Show-Check "BigStitcher-Spark" $hasSpark  $(if ($hasSpark) { $sparkJar } else { "build into $toolsDir\BigStitcher-Spark  (see luxendo\INSTALL.md section 4)" })
Show-Check "Dataset (bdv.xml)" $hasData   $(if ($hasData) { $bdv } else { "place your Luxendo bdv.xml + bdv.h5 under $BaseDir" })
Show-Check "python on PATH"    $hasPython $(if ($hasPython) { $pythonCmd.Source } else { "install Python 3 + numpy/h5py  (see luxendo\INSTALL.md section 5)" })
Write-Host ""

if (-not ($hasSpark -and $hasData -and $hasPython)) {
    Write-Host "Fiji is wired up, but the Spark pipeline is not ready to run yet (only Fiji so far)." -ForegroundColor Yellow
    Write-Host "Finish the [MISS] items above, then re-run this launcher (extra args pass through to run_pipeline.ps1):"
    Write-Host "  .\$(Split-Path -Leaf $MyInvocation.MyCommand.Path) -SeparateViews -ExportBigTiff"
    Write-Host ""
    Write-Host "Note: the classic BigStitcher route (run-bigstitcher-classic.cmd / run-fiji-headless.cmd) needs only Fiji"
    Write-Host "      and works now, without building BigStitcher-Spark."
    exit 0
}

# --- Launch run_pipeline.ps1 -----------------------------------------------
$pipeline = Join-Path $toolsDir 'run_pipeline.ps1'
if (-not (Test-Path -LiteralPath $pipeline)) {
    throw "run_pipeline.ps1 was not found next to this launcher: $pipeline"
}

# run_pipeline.ps1 resolves bdv.xml at -DatasetRoot or in its parents, so hand it the
# folder that actually contains bdv.xml (the base folder itself if it is there).
$datasetRoot = Split-Path -Parent $bdv
$runArgs = @('-DatasetRoot', $datasetRoot)
if ($args.Count -gt 0) { $runArgs += $args }

Write-Host "Launching: run_pipeline.ps1 $($runArgs -join ' ')"
& $pipeline @runArgs
exit $LASTEXITCODE
