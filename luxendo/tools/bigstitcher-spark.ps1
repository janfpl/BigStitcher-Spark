$ErrorActionPreference = "Stop"

if ($args.Count -lt 1) {
    throw "Usage: bigstitcher-spark.cmd <command> [tool arguments]"
}

$Command = [string]$args[0]
$ToolArgs = @()
if ($args.Count -gt 1) {
    $ToolArgs = @($args[1..($args.Count - 1)])
}

$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir = Join-Path $toolsDir "BigStitcher-Spark"
$javaRoot = Get-ChildItem -Directory (Join-Path $toolsDir "fiji\Fiji.app\java\win64") |
    Where-Object { $_.Name -like "*jdk*" } |
    Select-Object -First 1

if (-not $javaRoot) {
    throw "Could not find Fiji-bundled JDK under $toolsDir\fiji\Fiji.app\java\win64"
}

$jar = Join-Path $repoDir "target\BigStitcher-Spark-0.1.0-SNAPSHOT.jar"
$deps = Join-Path $repoDir "target\dependency\*"
$sparkDeps = Join-Path $repoDir "target\dependency-provided\*"

if (-not (Test-Path $jar)) {
    throw "BigStitcher-Spark jar not found at $jar. Run Maven package first."
}

$classes = @{
    "resave" = "net.preibisch.bigstitcher.spark.SparkResaveN5"
    "detect-interestpoints" = "net.preibisch.bigstitcher.spark.SparkInterestPointDetection"
    "match-interestpoints" = "net.preibisch.bigstitcher.spark.SparkGeometricDescriptorMatching"
    "stitching" = "net.preibisch.bigstitcher.spark.SparkPairwiseStitching"
    "solver" = "net.preibisch.bigstitcher.spark.Solver"
    "match-intensities" = "net.preibisch.bigstitcher.spark.SparkIntensityMatching"
    "solve-intensities" = "net.preibisch.bigstitcher.spark.IntensitySolver"
    "create-fusion-container" = "net.preibisch.bigstitcher.spark.CreateFusionContainer"
    "affine-fusion" = "net.preibisch.bigstitcher.spark.SparkAffineFusion"
    "nonrigid-fusion" = "net.preibisch.bigstitcher.spark.SparkNonRigidFusion"
    "split-images" = "net.preibisch.bigstitcher.spark.SplitDatasets"
    "downsample" = "net.preibisch.bigstitcher.spark.SparkDownsample"
    "clear-interestpoints" = "net.preibisch.bigstitcher.spark.ClearInterestPoints"
    "clear-registrations" = "net.preibisch.bigstitcher.spark.ClearRegistrations"
    "transform-points" = "net.preibisch.bigstitcher.spark.TransformPoints"
}

if (-not $classes.ContainsKey($Command)) {
    $valid = ($classes.Keys | Sort-Object) -join ", "
    throw "Unknown BigStitcher-Spark command '$Command'. Valid commands: $valid"
}

$threads = if ($env:BIGSTITCHER_SPARK_THREADS) { $env:BIGSTITCHER_SPARK_THREADS } else { "24" }
$memoryGb = if ($env:BIGSTITCHER_SPARK_MEMORY_GB) { $env:BIGSTITCHER_SPARK_MEMORY_GB } else { "64" }
$tmp = if ($env:BIGSTITCHER_TMP) { $env:BIGSTITCHER_TMP } else { Join-Path $toolsDir "tmp" }

New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$env:JAVA_HOME = $javaRoot.FullName
$java = Join-Path $env:JAVA_HOME "bin\java.exe"
if (-not (Test-Path -LiteralPath $java)) {
    # Some Fiji builds bundle the JVM with java.exe under <jdk>\jre\bin instead of <jdk>\bin.
    $java = Join-Path $env:JAVA_HOME "jre\bin\java.exe"
}
$classpath = "$jar;$deps;$sparkDeps"

& $java `
    "-Xmx${memoryGb}g" `
    "-Dspark.master=local[$threads]" `
    "-Djava.io.tmpdir=$tmp" `
    "-cp" $classpath `
    $classes[$Command] `
    @ToolArgs

exit $LASTEXITCODE
