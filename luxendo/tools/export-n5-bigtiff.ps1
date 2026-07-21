param(
    [string]$N5Path,

    [string]$Dataset = "setup0/timepoint0/s0",

    [Parameter(Mandatory = $true)]
    [string]$Output,

    [string]$Compression = "Uncompressed",

    [string]$VoxelSize = "",

    [string]$VoxelUnit = "micrometer",

    [int]$TileSize = 128,

    [int]$MemoryGb = 48,

    [switch]$Overwrite,

    [switch]$PatchExisting
)

$ErrorActionPreference = "Stop"

$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir = Join-Path $toolsDir "BigStitcher-Spark"
$javaSource = Join-Path $toolsDir "java\ExportN5BigTiff.java"
$classDir = Join-Path $toolsDir "java\classes"
$classFile = Join-Path $classDir "ExportN5BigTiff.class"
$javaRoot = Get-ChildItem -Directory (Join-Path $toolsDir "fiji\Fiji.app\java\win64") |
    Where-Object { $_.Name -like "*jdk*" } |
    Select-Object -First 1

if (-not $javaRoot) {
    throw "Could not find Fiji-bundled JDK under $toolsDir\fiji\Fiji.app\java\win64"
}

$jar = Join-Path $repoDir "target\BigStitcher-Spark-0.1.0-SNAPSHOT.jar"
$deps = Join-Path $repoDir "target\dependency\*"
$sparkDeps = Join-Path $repoDir "target\dependency-provided\*"
$classpath = "$classDir;$jar;$deps;$sparkDeps"

New-Item -ItemType Directory -Force -Path $classDir | Out-Null

$javac = Join-Path $javaRoot.FullName "bin\javac.exe"
$java = Join-Path $javaRoot.FullName "bin\java.exe"
if (-not (Test-Path -LiteralPath $java)) {
    # Some Fiji builds bundle the JVM with java.exe under <jdk>\jre\bin instead of <jdk>\bin.
    $java = Join-Path $javaRoot.FullName "jre\bin\java.exe"
}
if (-not (Test-Path -LiteralPath $javac)) {
    throw "No Java compiler at $javac (this Fiji appears to bundle a JRE only). Exporting BigTIFF compiles a small Java helper and needs a JDK. Install Zulu JDK 8 + FX and point the tools at it."
}

if ((-not (Test-Path -LiteralPath $classFile)) -or
    ((Get-Item -LiteralPath $javaSource).LastWriteTime -gt (Get-Item -LiteralPath $classFile).LastWriteTime)) {
    & $javac -cp "$jar;$deps;$sparkDeps" -d $classDir $javaSource
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to compile $javaSource"
    }
}

$arguments = @(
    "-Xmx${MemoryGb}g",
    "-cp", $classpath,
    "ExportN5BigTiff",
    "--out", $Output,
    "--compression", $Compression,
    "--voxel-unit", $VoxelUnit,
    "--tile-size", [string]$TileSize
)

if ($PatchExisting) {
    $arguments += "--patch-existing"
} else {
    if (-not $N5Path) {
        throw "-N5Path is required unless -PatchExisting is used."
    }
    $arguments += @("--n5", $N5Path, "--dataset", $Dataset)
}
if ($VoxelSize) {
    $arguments += @("--voxel-size", $VoxelSize)
}
if ($Overwrite) {
    $arguments += "--overwrite"
}

& $java @arguments
exit $LASTEXITCODE
