$ErrorActionPreference = "Stop"

$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$javaRoot = Get-ChildItem -Directory (Join-Path $toolsDir "fiji\Fiji.app\java\win64") |
    Where-Object { $_.Name -like "*jdk*" } |
    Select-Object -First 1

if (-not $javaRoot) {
    throw "Could not find Fiji-bundled JDK under $toolsDir\fiji\Fiji.app\java\win64"
}

$java = Join-Path $javaRoot.FullName "bin\java.exe"
if (-not (Test-Path -LiteralPath $java)) {
    # Some Fiji builds bundle the JVM with java.exe under <jdk>\jre\bin instead of <jdk>\bin.
    $java = Join-Path $javaRoot.FullName "jre\bin\java.exe"
}
$classes = Join-Path $toolsDir "java\classes"
$classpath = "$classes;$toolsDir\fiji\Fiji.app\plugins\Big_Stitcher-2.6.1.jar;$toolsDir\fiji\Fiji.app\plugins\multiview_reconstruction-8.1.2.jar;$toolsDir\fiji\Fiji.app\plugins\SPIM_Registration-5.0.26.jar;$toolsDir\fiji\Fiji.app\jars\*;$toolsDir\fiji\Fiji.app\plugins\*"
$memoryGb = if ($env:BIGSTITCHER_CLASSIC_MEMORY_GB) { $env:BIGSTITCHER_CLASSIC_MEMORY_GB } else { "64" }

& $java "-Xmx${memoryGb}g" -cp $classpath RunBigStitcherFusion @args
exit $LASTEXITCODE
