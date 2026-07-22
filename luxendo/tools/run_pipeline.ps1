param(
    [string]$DatasetRoot = "D:\0825_UPMC_MERCY\2025-08-19-organoid\2025-08-19_092453",
    [string]$OutputRoot = "",
    # Acquisition handling. "auto" inspects bdv.xml and chooses tiled vs multiview defaults.
    [ValidateSet("auto", "tiled", "multiview")]
    [string]$AcquisitionType = "auto",
    # Output resampling. "auto" -> anisotropic for tiled, isotropic for multiview.
    [ValidateSet("auto", "anisotropic", "isotropic")]
    [string]$Sampling = "auto",
    # Registration engine. STITCHING = phase-correlation (translation links). INTERESTPOINTS = DoG
    # interest points + geometric/ICP matching, the only path that yields a real affine solve.
    [ValidateSet("STITCHING", "INTERESTPOINTS")]
    [string]$RegistrationMode = "STITCHING",
    [switch]$ExportBigTiff,
    [switch]$OnlyExportBigTiff,
    [switch]$BigTiffOnlyOutput,
    [switch]$SeparateViews,
    [switch]$OnlySeparateViews,
    [switch]$TilesAsAnglesReg,
    [switch]$FirstStackAsZero,
    [string]$ChannelIds = "",
    [int]$RegSubtract = 150,
    [int]$FusionSubtract = 100,
    [ValidateSet("", "TRANSLATION", "RIGID", "AFFINE")]
    [string]$SolverTransformModel = "",
    [ValidateSet("NONE", "IDENTITY", "TRANSLATION", "RIGID", "AFFINE")]
    [string]$SolverRegularizationModel = "",
    # Interest-point registration parameters (used when -RegistrationMode INTERESTPOINTS).
    [string]$IpLabel = "nuclei",
    [double]$IpSigma = 1.8,
    [double]$IpThreshold = 0.008,
    [string]$IpMinIntensity = "",
    [string]$IpMaxIntensity = "",
    [int]$IpDownsampleXY = 2,
    [int]$IpDownsampleZ = 1,
    [ValidateSet("MIN", "MAX", "BOTH")]
    [string]$IpType = "MAX",
    [ValidateSet("FAST_ROTATION", "FAST_TRANSLATION", "PRECISE_TRANSLATION")]
    [string]$IpMatchMethod = "FAST_ROTATION",
    [switch]$IpOverlappingOnly,
    [switch]$IpRefineICP,
    [int]$IpMaxSpots = 0,
    # Pairwise stitching parameters (used when -RegistrationMode STITCHING).
    [string]$StitchDownsampling = "8,8,4",
    [int]$StitchPeaks = 10,
    [double]$StitchMinR = 0.03,
    [double]$StitchMaxR = 0.9999,
    [string]$BigTiffOutput = "",
    [string]$BigTiffCompression = "Uncompressed",
    [int]$BigTiffMemoryGb = 48,
    [int]$BigTiffTileSize = 128,
    [string]$SeparateViewsOutputRoot = ""
)

$ErrorActionPreference = "Stop"

# Track which switches/values the caller explicitly set, so auto-detection only fills in defaults
# the user did not override.
$script:userSetTilesAsAnglesReg = $PSBoundParameters.ContainsKey("TilesAsAnglesReg")
$script:userSetFirstStackAsZero = $PSBoundParameters.ContainsKey("FirstStackAsZero")

$runStartedAt = Get-Date
$runStamp = $runStartedAt.ToString("HHmm_MMddyyyy", [System.Globalization.CultureInfo]::InvariantCulture)

$datasetRoot = [System.IO.Path]::GetFullPath($DatasetRoot)
if (-not (Test-Path -LiteralPath $datasetRoot)) {
    throw "Dataset root does not exist: $datasetRoot"
}

# Accept a dataset root that contains bdv.xml, or resolve it from a few parent levels (e.g. when the
# caller points at a 'raw' subfolder whose bdv.xml/bdv.h5 live one level up).
if (-not (Test-Path -LiteralPath (Join-Path $datasetRoot "bdv.xml"))) {
    $searchDir = $datasetRoot
    $resolvedRoot = $null
    for ($depth = 0; $depth -lt 4 -and $searchDir; $depth++) {
        if (Test-Path -LiteralPath (Join-Path $searchDir "bdv.xml")) {
            $resolvedRoot = $searchDir
            break
        }
        $searchDir = Split-Path -Parent $searchDir
    }
    if (-not $resolvedRoot) {
        throw "Could not find bdv.xml in '$datasetRoot' or its parent folders. Point -DatasetRoot at the folder that contains bdv.xml and bdv.h5."
    }
    if ($resolvedRoot -ne $datasetRoot) {
        Write-Host "Located bdv.xml in '$resolvedRoot' (resolved from '$datasetRoot'); using it as the dataset root."
        $datasetRoot = $resolvedRoot
    }
}

$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputRoot = if ($OutputRoot) {
    [System.IO.Path]::GetFullPath($OutputRoot)
} else {
    Join-Path $datasetRoot ("processed\bigstitcher_spark_{0}" -f $runStamp)
}
$logs = Join-Path $outputRoot "logs"
$bdvXmlDir = Join-Path $outputRoot "bdv_xml"
$inputRoot = Join-Path $outputRoot "input"
$outputDataRoot = Join-Path $outputRoot "output"
$n5OutputRoot = Join-Path $outputDataRoot "n5"
$bigTiffOutputRoot = Join-Path $outputDataRoot "bigtiff"
$int16Dir = Join-Path $inputRoot "int16_input"
$fusionInt16Dir = Join-Path $inputRoot "int16_fusion_input"
$rawN5 = Join-Path $inputRoot "raw_multires.n5"
$fusionRawN5 = Join-Path $inputRoot "raw_multires_restored_for_fusion.n5"
$datasetN5Xml = Join-Path $bdvXmlDir "dataset_n5.xml"
$datasetFusionN5Xml = Join-Path $bdvXmlDir "dataset_n5_restored_for_fusion.xml"
$datasetIsotropicXml = Join-Path $bdvXmlDir "dataset_n5_isotropic.xml"
$fusionMetadataJson = Join-Path $logs "fusion_sampling.json"
$legacyFusionMetadataJson = Join-Path $outputRoot "fusion_sampling.json"
$fusedN5 = Join-Path $n5OutputRoot "full_isotropic_fused.n5"
$fusedXml = Join-Path $bdvXmlDir "full_isotropic_fused.xml"
$separateViewsRoot = if ($SeparateViewsOutputRoot) {
    [System.IO.Path]::GetFullPath($SeparateViewsOutputRoot)
} else {
    Join-Path $n5OutputRoot "separate_views"
}
$separateViewsN5 = Join-Path $separateViewsRoot "registered_views.n5"
$separateViewsXml = Join-Path $bdvXmlDir "registered_views.xml"
$separateViewsBigTiffDir = if ($SeparateViewsOutputRoot) {
    Join-Path $separateViewsRoot "bigtiff"
} else {
    Join-Path $bigTiffOutputRoot "separate_views"
}
$bigTiff = if ($BigTiffOutput) {
    [System.IO.Path]::GetFullPath($BigTiffOutput)
} else {
    Join-Path $bigTiffOutputRoot "full_isotropic_fused_s0_bigtiff.tif"
}
$script:isotropicVoxelSize = ""

if ($BigTiffOnlyOutput) {
    $ExportBigTiff = $true
}
# Resolve the transform model default per registration engine: phase-correlation stitching only
# yields translation links (so TRANSLATION is the sensible default), while the interest-point path
# can constrain a real AFFINE solve.
if (-not $SolverTransformModel) {
    $SolverTransformModel = if ($RegistrationMode -eq "INTERESTPOINTS") { "AFFINE" } else { "TRANSLATION" }
}
if (-not $SolverRegularizationModel) {
    $SolverRegularizationModel = $SolverTransformModel
}
if ($RegSubtract -lt 0) {
    throw "RegSubtract must be non-negative"
}
if ($FusionSubtract -lt 0) {
    throw "FusionSubtract must be non-negative"
}
if ($RegistrationMode -eq "INTERESTPOINTS") {
    if (-not $IpMinIntensity -or -not $IpMaxIntensity) {
        throw "INTERESTPOINTS mode requires -IpMinIntensity and -IpMaxIntensity (DoG normalizes each block to [0,1]). The int16 mirror stores uint16 bit patterns, so voxels above 32767 wrap negative; choose a range that covers the signed values present, e.g. -IpMinIntensity -32768 -IpMaxIntensity 32767."
    }
}

$env:BIGSTITCHER_SPARK_THREADS = "46"
$env:BIGSTITCHER_SPARK_MEMORY_GB = "224"
$env:BIGSTITCHER_TMP = Join-Path $outputRoot "tmp"

New-Item -ItemType Directory -Force -Path $outputRoot, $logs, $bdvXmlDir, $inputRoot, $n5OutputRoot, $bigTiffOutputRoot, $env:BIGSTITCHER_TMP | Out-Null

function Write-PipelineStatus([string]$message) {
    "$(Get-Date -Format o) $message" | Add-Content -LiteralPath (Join-Path $logs "pipeline_status.log")
}

[Environment]::CommandLine | Set-Content -LiteralPath (Join-Path $logs "pipeline.command.txt")
$PID | Set-Content -LiteralPath (Join-Path $logs "pipeline.pid") -NoNewline
Write-PipelineStatus "START outputRoot=$outputRoot"
Write-PipelineStatus "INTENSITY RegSubtract=$RegSubtract FusionSubtract=$FusionSubtract"

function Convert-ToFileUri([string]$path) {
    return ([System.Uri]::new($path)).AbsoluteUri
}

function Convert-ToRelativePath([string]$fromDirectory, [string]$toPath) {
    $fromFull = [System.IO.Path]::GetFullPath($fromDirectory)
    if (-not $fromFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $fromFull = $fromFull + [System.IO.Path]::DirectorySeparatorChar
    }
    $toFull = [System.IO.Path]::GetFullPath($toPath)

    $fromUri = [System.Uri]::new($fromFull)
    $toUri = [System.Uri]::new($toFull)
    return $fromUri.MakeRelativeUri($toUri).ToString()
}

function Remove-GeneratedPath([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) {
        return
    }

    $resolved = (Resolve-Path -LiteralPath $path).Path
    if (-not $resolved.StartsWith($outputRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to delete path outside output root: $resolved"
    }

    Remove-Item -LiteralPath $resolved -Recurse -Force
}

function Get-N5DatasetBlockCount([string]$n5Path, [string]$dataset) {
    $datasetPath = Join-Path $n5Path ($dataset -replace "/", [System.IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $datasetPath)) {
        return 0
    }

    return @(
        Get-ChildItem -LiteralPath $datasetPath -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne "attributes.json" }
    ).Count
}

function Convert-ToInvariantString([double]$value) {
    return $value.ToString("R", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Save-XmlUtf8NoBom([xml]$doc, [string]$xmlPath) {
    $settings = [System.Xml.XmlWriterSettings]::new()
    $settings.Encoding = [System.Text.UTF8Encoding]::new($false)
    $settings.Indent = $true
    $settings.NewLineChars = "`n"

    $writer = [System.Xml.XmlWriter]::Create($xmlPath, $settings)
    try {
        $doc.Save($writer)
    } finally {
        $writer.Dispose()
    }
}

function Set-BdvXmlN5RelativePath([string]$xmlPath, [string]$n5Path) {
    [xml]$doc = Get-Content -LiteralPath $xmlPath -Raw
    $basePath = $doc.SelectSingleNode("/SpimData/BasePath")
    if ($null -eq $basePath) {
        $root = $doc.SelectSingleNode("/SpimData")
        if ($null -eq $root) {
            throw "XML has no /SpimData root: $xmlPath"
        }
        $basePath = $doc.CreateElement("BasePath")
        [void]$root.PrependChild($basePath)
    }
    $basePath.SetAttribute("type", "relative")
    $basePath.InnerText = "."

    $loader = $doc.SelectSingleNode("/SpimData/SequenceDescription/ImageLoader")
    if ($null -eq $loader) {
        throw "XML has no /SpimData/SequenceDescription/ImageLoader node: $xmlPath"
    }
    $n5 = $loader.SelectSingleNode("n5")
    if ($null -eq $n5) {
        $n5 = $doc.CreateElement("n5")
        [void]$loader.AppendChild($n5)
    }
    $n5.SetAttribute("type", "relative")
    $n5.InnerText = Convert-ToRelativePath (Split-Path -Parent $xmlPath) $n5Path
    Save-XmlUtf8NoBom $doc $xmlPath
}

function Set-DatasetN5XmlFamilyRelativePaths() {
    if (-not (Test-Path -LiteralPath $bdvXmlDir)) {
        return
    }

    Get-ChildItem -LiteralPath $bdvXmlDir -File |
        Where-Object {
            $_.Name -like "dataset_n5*" -and
            $_.Name -notlike "*isotropic*" -and
            $_.Name -notlike "*fusion*" -and
            $_.Name -notlike "*restored*"
        } |
        ForEach-Object {
            Set-BdvXmlN5RelativePath $_.FullName $rawN5
        }
}

function Initialize-FusionVoxelSize() {
    if ($script:isotropicVoxelSize) {
        return
    }
    $metadataPath = $fusionMetadataJson
    if (-not (Test-Path -LiteralPath $metadataPath) -and (Test-Path -LiteralPath $legacyFusionMetadataJson)) {
        $metadataPath = $legacyFusionMetadataJson
    }
    if (-not (Test-Path -LiteralPath $metadataPath)) {
        throw "Fusion sampling metadata is missing: $fusionMetadataJson"
    }

    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    $values = @($metadata.output_voxel_size)
    if ($values.Count -ne 3) {
        throw "Expected three output voxel sizes in $metadataPath"
    }

    $script:isotropicVoxelSize = (($values | ForEach-Object {
        Convert-ToInvariantString ([double]$_)
    }) -join " ")
}

function Get-FusionVoxelSizeCsv() {
    Initialize-FusionVoxelSize
    return $script:isotropicVoxelSize -replace " ", ","
}

function Invoke-Logged([string]$name, [string]$exe, [string[]]$arguments) {
    $log = Join-Path $logs "$name.log"
    $exitFile = Join-Path $logs "$name.exitcode"
    "START $(Get-Date -Format o)" | Set-Content -LiteralPath $log
    "COMMAND $exe $($arguments -join ' ')" | Add-Content -LiteralPath $log

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $exe @arguments >> $log 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference

    "END $(Get-Date -Format o) ExitCode=$code" | Add-Content -LiteralPath $log
    $code | Set-Content -LiteralPath $exitFile -NoNewline
    if ($code -ne 0) {
        throw "$name failed with exit code $code. See $log"
    }
}

function Invoke-PythonLogged([string]$name, [string[]]$arguments) {
    Invoke-Logged $name "python" $arguments
}

function Invoke-SparkLogged([string]$name, [string[]]$arguments) {
    Invoke-Logged $name (Join-Path $toolsRoot "bigstitcher-spark.cmd") $arguments
}

function Convert-ToSafeName([string]$name) {
    $safe = $name -replace '[^\p{L}\p{Nd}_.-]+', '_'
    $safe = $safe.Trim('_')
    if (-not $safe) {
        return "view"
    }
    if ($safe.Length -gt 120) {
        return $safe.Substring(0, 120)
    }
    return $safe
}

function Get-RegisteredViewSetups([string]$xmlPath) {
    [xml]$doc = Get-Content -LiteralPath $xmlPath -Raw
    @($doc.SpimData.SequenceDescription.ViewSetups.ViewSetup) |
        Sort-Object { [int]$_.id } |
        ForEach-Object {
            [PSCustomObject]@{
                Id = [int]$_.id
                Name = [string]$_.name
                ChannelId = if ($_.attributes -and $_.attributes.channel) { [int]$_.attributes.channel } else { 0 }
                AngleId = if ($_.attributes -and $_.attributes.angle) { [int]$_.attributes.angle } else { 0 }
                IlluminationId = if ($_.attributes -and $_.attributes.illumination) { [int]$_.attributes.illumination } else { 0 }
                TileId = if ($_.attributes -and $_.attributes.tile) { [int]$_.attributes.tile } else { 0 }
                SafeName = Convert-ToSafeName ([string]$_.name)
            }
        }
}

function Get-SetupIdsForChannelFilter([string]$xmlPath, [string]$channelIds) {
    if (-not $channelIds) {
        return ""
    }

    [xml]$doc = Get-Content -LiteralPath $xmlPath -Raw
    $selectedChannels = @{}
    foreach ($item in ($channelIds -split ",")) {
        $trimmed = $item.Trim()
        if (-not $trimmed) {
            continue
        }
        $selectedChannels[[int]$trimmed] = $true
    }

    if ($selectedChannels.Count -eq 0) {
        return ""
    }

    $setupIds = @($doc.SpimData.SequenceDescription.ViewSetups.ViewSetup |
        Where-Object {
            $_.attributes -and $_.attributes.channel -and $selectedChannels.ContainsKey([int]$_.attributes.channel)
        } |
        Sort-Object { [int]$_.id } |
        ForEach-Object { [string]$_.id })

    if ($setupIds.Count -eq 0) {
        throw "No ViewSetup entries in $xmlPath match ChannelIds=$channelIds"
    }

    return ($setupIds -join ",")
}

function Get-FusionChannels([string]$xmlPath) {
    [xml]$doc = Get-Content -LiteralPath $xmlPath -Raw
    # Wrap the whole sorted pipeline in @(...) so a single channel stays a one-item array. Without
    # the outer @(), PowerShell unrolls one piped item to a scalar XmlElement, so $channels.Count
    # and the index loop below misbehave and emit no channels.
    $channels = @(@($doc.SelectNodes("/SpimData/SequenceDescription/ViewSetups/Attributes[@name='channel']/*")) |
        Sort-Object { [int]$_.id })

    if ($channels.Count -eq 0) {
        [PSCustomObject]@{
            Index = 0
            Id = 0
            Name = "channel0"
            SafeName = "channel0"
        }
        return
    }

    for ($i = 0; $i -lt $channels.Count; $i++) {
        $channel = $channels[$i]
        $name = if ($channel.name) {
            [string]$channel.name
        } else {
            "channel$($channel.id)"
        }

        [PSCustomObject]@{
            Index = $i
            Id = [int]$channel.id
            Name = $name
            SafeName = Convert-ToSafeName $name
        }
    }
}

function Get-FinalBigTiffOutputForChannel([object]$channel, [int]$channelCount) {
    if ($channelCount -le 1) {
        return $bigTiff
    }

    $dir = Split-Path -Parent $bigTiff
    $leaf = [System.IO.Path]::GetFileNameWithoutExtension($bigTiff)
    $ext = [System.IO.Path]::GetExtension($bigTiff)
    $channelLabel = "ch$($channel.Id)"
    if ($leaf -match "_s0_bigtiff$") {
        $leaf = $leaf -replace "_s0_bigtiff$", ("_{0}_s0_bigtiff" -f $channelLabel)
    } else {
        $leaf = "{0}_{1}" -f $leaf, $channelLabel
    }
    return Join-Path $dir ($leaf + $ext)
}

function Invoke-TilesAsAnglesRegistrationNormalization([string]$xmlPath) {
    if (-not $TilesAsAnglesReg) {
        return
    }
    if (-not (Test-Path -LiteralPath $xmlPath)) {
        throw "Cannot normalize tile IDs for angle registration because XML is missing: $xmlPath"
    }

    $log = Join-Path $logs "01b_tiles_as_angles_reg.log"
    $exitFile = Join-Path $logs "01b_tiles_as_angles_reg.exitcode"
    "START $(Get-Date -Format o)" | Set-Content -LiteralPath $log

    try {
        $backup = Join-Path $bdvXmlDir "dataset_n5.before_tiles_as_angles_reg.xml"
        Copy-Item -LiteralPath $xmlPath -Destination $backup -Force

        [xml]$doc = Get-Content -LiteralPath $xmlPath -Raw
        $viewSetups = $doc.SelectSingleNode("/SpimData/SequenceDescription/ViewSetups")
        if ($null -eq $viewSetups) {
            throw "XML has no /SpimData/SequenceDescription/ViewSetups node: $xmlPath"
        }

        $setups = @($doc.SelectNodes("/SpimData/SequenceDescription/ViewSetups/ViewSetup"))
        if ($setups.Count -eq 0) {
            throw "XML has no ViewSetup entries to normalize: $xmlPath"
        }

        $changed = 0
        foreach ($setup in $setups) {
            $attributes = $setup.SelectSingleNode("attributes")
            if ($null -eq $attributes) {
                $attributes = $doc.CreateElement("attributes")
                [void]$setup.AppendChild($attributes)
            }

            $tile = $attributes.SelectSingleNode("tile")
            if ($null -eq $tile) {
                $tile = $doc.CreateElement("tile")
                [void]$attributes.AppendChild($tile)
            }

            if ($tile.InnerText.Trim() -ne "0") {
                $changed++
            }
            $tile.InnerText = "0"
        }

        $tileAttributeNodes = @($doc.SelectNodes("/SpimData/SequenceDescription/ViewSetups/Attributes[@name='tile']"))
        if ($tileAttributeNodes.Count -eq 0) {
            $tileAttributes = $doc.CreateElement("Attributes")
            $tileAttributes.SetAttribute("name", "tile")
            [void]$viewSetups.AppendChild($tileAttributes)
            $tileAttributeNodes = @($tileAttributes)
        }

        foreach ($tileAttributes in $tileAttributeNodes) {
            while ($tileAttributes.FirstChild) {
                [void]$tileAttributes.RemoveChild($tileAttributes.FirstChild)
            }

            $tileElement = $doc.CreateElement("Tile")
            $idElement = $doc.CreateElement("id")
            $idElement.InnerText = "0"
            $nameElement = $doc.CreateElement("name")
            $nameElement.InnerText = "tiles_as_angles_reg"

            [void]$tileElement.AppendChild($idElement)
            [void]$tileElement.AppendChild($nameElement)
            [void]$tileAttributes.AppendChild($tileElement)
        }

        Save-XmlUtf8NoBom $doc $xmlPath
        "Backed up original working XML to $backup" | Add-Content -LiteralPath $log
        "Normalized $($setups.Count) ViewSetup tile assignment(s) to tile 0; changed $changed existing assignment(s)." |
            Add-Content -LiteralPath $log
        "Preserved setup IDs, names, angles, channels, image paths, and registrations." |
            Add-Content -LiteralPath $log
        "END $(Get-Date -Format o) ExitCode=0" | Add-Content -LiteralPath $log
        "0" | Set-Content -LiteralPath $exitFile -NoNewline
    } catch {
        "ERROR $($_.Exception.Message)" | Add-Content -LiteralPath $log
        "END $(Get-Date -Format o) ExitCode=1" | Add-Content -LiteralPath $log
        "1" | Set-Content -LiteralPath $exitFile -NoNewline
        throw
    }
}

function Set-BdvXmlVoxelSize([string]$xmlPath) {
    Initialize-FusionVoxelSize
    [xml]$doc = Get-Content -LiteralPath $xmlPath -Raw
    foreach ($setup in $doc.SpimData.SequenceDescription.ViewSetups.ViewSetup) {
        $setup.voxelSize.unit = "micrometer"
        $setup.voxelSize.size = $script:isotropicVoxelSize
    }
    Save-XmlUtf8NoBom $doc $xmlPath
}

function Set-SeparateViewsXmlMetadata([string]$xmlPath, [object[]]$views) {
    [xml]$doc = Get-Content -LiteralPath $xmlPath -Raw
    for ($i = 0; $i -lt $views.Count; $i++) {
        $view = $views[$i]
        $label = "input setup $($view.Id): $($view.Name)"
        $setup = @($doc.SpimData.SequenceDescription.ViewSetups.ViewSetup) |
            Where-Object { [int]$_.id -eq $i } |
            Select-Object -First 1
        if ($setup) {
            $setup.name = $label
        }

        $channel = @($doc.SpimData.SequenceDescription.ViewSetups.Attributes |
            Where-Object { $_.name -eq "channel" }).Channel |
            Where-Object { [int]$_.id -eq $i } |
            Select-Object -First 1
        if ($channel) {
            $channel.name = $label
        }
    }
    Save-XmlUtf8NoBom $doc $xmlPath
}

function Invoke-BigTiffDatasetExport(
    [string]$name,
    [string]$n5Path,
    [string]$dataset,
    [string]$outputTiff
) {
    if (-not (Test-Path -LiteralPath $n5Path)) {
        throw "Cannot export BigTIFF because N5 is missing: $n5Path"
    }

    Invoke-Logged $name "powershell.exe" @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $toolsRoot "export-n5-bigtiff.ps1"),
        "-N5Path", $n5Path,
        "-Dataset", $dataset,
        "-Output", $outputTiff,
        "-Compression", $BigTiffCompression,
        "-VoxelSize", (Get-FusionVoxelSizeCsv),
        "-VoxelUnit", "micrometer",
        "-TileSize", [string]$BigTiffTileSize,
        "-MemoryGb", [string]$BigTiffMemoryGb,
        "-Overwrite"
    )
}

function Initialize-OffsetN5DatasetTool() {
    if ($script:offsetN5DatasetToolReady) {
        return
    }

    $repoDir = Join-Path $toolsRoot "BigStitcher-Spark"
    $javaSource = Join-Path $toolsRoot "java\OffsetN5Dataset.java"
    $classDir = Join-Path $toolsRoot "java\classes"
    $classFile = Join-Path $classDir "OffsetN5Dataset.class"
    $javaRoot = Get-ChildItem -Directory (Join-Path $toolsRoot "fiji\Fiji.app\java\win64") |
        Where-Object { $_.Name -like "*jdk*" } |
        Select-Object -First 1

    if (-not $javaRoot) {
        throw "Could not find Fiji-bundled JDK under $toolsRoot\fiji\Fiji.app\java\win64"
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
        # Fiji bundles a JRE (no javac); fall back to a system JDK via JAVA_HOME, then PATH.
        $javac = $null
        if ($env:JAVA_HOME -and (Test-Path -LiteralPath (Join-Path $env:JAVA_HOME "bin\javac.exe"))) {
            $javac = Join-Path $env:JAVA_HOME "bin\javac.exe"
        } else {
            $javacCmd = Get-Command javac -ErrorAction SilentlyContinue
            if ($javacCmd) { $javac = $javacCmd.Source }
        }
        if (-not $javac) {
            throw "No Java compiler found: Fiji bundles a JRE (no javac) and none was found via JAVA_HOME or PATH. The background-subtract step (FusionSubtract, on by default) compiles a small Java helper and needs a JDK. Install Zulu JDK 8 + FX (set JAVA_HOME), or run with -FusionSubtract 0."
        }
    }

    if ((-not (Test-Path -LiteralPath $classFile)) -or
        ((Get-Item -LiteralPath $javaSource).LastWriteTime -gt (Get-Item -LiteralPath $classFile).LastWriteTime)) {
        Invoke-Logged "00b_compile_offset_n5_dataset" $javac @(
            "-cp", "$jar;$deps;$sparkDeps",
            "-d", $classDir,
            $javaSource
        )
    }

    $script:offsetN5DatasetJava = $java
    $script:offsetN5DatasetClasspath = $classpath
    $script:offsetN5DatasetToolReady = $true
}

function Get-N5ResolutionDatasets([string]$n5Path, [int]$setupIndex) {
    $timepointDir = Join-Path $n5Path ("setup{0}\timepoint0" -f $setupIndex)
    if (-not (Test-Path -LiteralPath $timepointDir)) {
        return @()
    }

    @(Get-ChildItem -LiteralPath $timepointDir -Directory |
        Where-Object { $_.Name -match '^s\d+$' } |
        Sort-Object { [int]($_.Name.Substring(1)) } |
        ForEach-Object { "setup$setupIndex/timepoint0/$($_.Name)" })
}

function Invoke-N5DatasetOffset([string]$name, [string]$n5Path, [string]$dataset, [int]$offset) {
    Initialize-OffsetN5DatasetTool
    Invoke-Logged $name $script:offsetN5DatasetJava @(
        "-Xmx${BigTiffMemoryGb}g",
        "-cp", $script:offsetN5DatasetClasspath,
        "OffsetN5Dataset",
        "--n5", $n5Path,
        "--dataset", $dataset,
        "--offset", [string]$offset
    )
}

function Invoke-FusionSubtractForSetup([string]$namePrefix, [string]$n5Path, [int]$setupIndex) {
    if ($FusionSubtract -eq 0) {
        return
    }

    $datasets = @(Get-N5ResolutionDatasets $n5Path $setupIndex)
    if ($datasets.Count -eq 0) {
        Write-PipelineStatus "WARNING FusionSubtract skipped because setup$setupIndex has no resolution datasets in $n5Path"
        return
    }

    $offset = -1 * $FusionSubtract
    foreach ($dataset in $datasets) {
        $suffix = ($dataset -replace "/", "_")
        Invoke-N5DatasetOffset ("{0}_{1}" -f $namePrefix, $suffix) $n5Path $dataset $offset
    }
}

function Invoke-FinalFusionSubtract() {
    if ($FusionSubtract -eq 0) {
        return
    }

    $channels = @(Get-FusionChannels $datasetIsotropicXml)
    foreach ($channel in $channels) {
        Invoke-FusionSubtractForSetup ("06b_subtract_final_fusion_ch{0}" -f $channel.Id) $fusedN5 $channel.Index
    }
    Write-PipelineStatus "COMPLETED FusionSubtract=$FusionSubtract for final fused N5"
}

function Invoke-TransformQuantification([string]$afterXml, [string]$beforeXml, [string]$outStem) {
    $transformScript = Join-Path $toolsRoot "quantify_registration_transforms.py"
    $args = @(
        $transformScript,
        "--after-xml", $afterXml,
        "--out-tsv", (Join-Path $logs "$outStem.tsv"),
        "--out-json", (Join-Path $logs "$outStem.json"),
        "--timepoint", "0"
    )
    if ($beforeXml -and (Test-Path -LiteralPath $beforeXml)) {
        $args += @("--before-xml", $beforeXml)
    }

    Invoke-PythonLogged ("03b_{0}" -f $outStem) $args
}

function Copy-N5DatasetDirectory(
    [string]$sourceN5,
    [string]$sourceDataset,
    [string]$destinationN5,
    [string]$destinationDataset
) {
    $sourcePath = Join-Path $sourceN5 ($sourceDataset -replace "/", [System.IO.Path]::DirectorySeparatorChar)
    $destinationPath = Join-Path $destinationN5 ($destinationDataset -replace "/", [System.IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "Cannot copy N5 dataset because source is missing: $sourcePath"
    }

    Remove-GeneratedPath $destinationPath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destinationPath) | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination (Split-Path -Parent $destinationPath) -Recurse -Force
}

function Invoke-SingleChannelSeparateViewFallback([object]$view, [int]$outputIndex, [string]$outputDataset) {
    $scratchRoot = Join-Path $env:BIGSTITCHER_TMP ("separate_view_setup{0}" -f $view.Id)
    $scratchN5 = Join-Path $scratchRoot "registered_view.n5"
    $scratchXml = Join-Path $scratchRoot "registered_view.xml"

    Remove-GeneratedPath $scratchRoot
    New-Item -ItemType Directory -Force -Path $scratchRoot | Out-Null

    Invoke-SparkLogged ("10d_create_single_channel_separate_view_setup{0}" -f $view.Id) @(
        "create-fusion-container",
        "-x", (Convert-ToFileUri $datasetIsotropicXml),
        "-o", (Convert-ToFileUri $scratchN5),
        "-s", "N5",
        "--bdv",
        "-xo", (Convert-ToFileUri $scratchXml),
        "-tp", "1",
        "-ch", "1",
        "-d", "UINT16",
        "--minIntensity", "0",
        "--maxIntensity", "65535",
        "-c", "Zstandard",
        "-cl", "1",
        "--blockSize", "128,128,128",
        "-ds", "1,1,1"
    )

    Invoke-SparkLogged ("10e_affine_single_channel_separate_view_setup{0}" -f $view.Id) @(
        "affine-fusion",
        "-o", (Convert-ToFileUri $scratchN5),
        "-s", "N5",
        "--localSparkBindAddress",
        "-f", "AVG_BLEND",
        "-t", "0",
        "-c", "0",
        "-vi", ("0,{0}" -f $view.Id),
        "--blockScale", "2,2,1"
    )

    $scratchDataset = "setup0/timepoint0/s0"
    $scratchBlockCount = Get-N5DatasetBlockCount $scratchN5 $scratchDataset
    if ($scratchBlockCount -eq 0) {
        throw "Single-channel fallback for setup $($view.Id) also wrote zero blocks"
    }

    Copy-N5DatasetDirectory $scratchN5 $scratchDataset $separateViewsN5 $outputDataset
    Remove-GeneratedPath $scratchRoot

    $blockCount = Get-N5DatasetBlockCount $separateViewsN5 $outputDataset
    Write-PipelineStatus (
        "SEPARATE-VIEW-FALLBACK setup {0} copied {1} block(s) from one-channel scratch output into output channel {2}" -f
        $view.Id,
        $blockCount,
        $outputIndex
    )
}

function Invoke-BigTiffExport() {
    $channels = @(Get-FusionChannels $datasetIsotropicXml)
    if ($channels.Count -eq 0) {
        throw "Cannot export final BigTIFF because no fusion channels were found in $datasetIsotropicXml"
    }

    $manifest = $null
    if ($channels.Count -gt 1) {
        $manifest = Join-Path (Split-Path -Parent $bigTiff) "full_isotropic_fused_bigtiff_manifest.tsv"
        "output_channel`tinput_channel_id`tinput_channel_name`tn5_dataset`tbigtiff" |
            Set-Content -LiteralPath $manifest
    }

    foreach ($channel in $channels) {
        $outputDataset = "setup$($channel.Index)/timepoint0/s0"
        $outputTiff = Get-FinalBigTiffOutputForChannel $channel $channels.Count
        $exportName = if ($channels.Count -eq 1) {
            "08_export_bigtiff"
        } else {
            "08_export_bigtiff_ch$($channel.Id)"
        }

        Invoke-BigTiffDatasetExport `
            $exportName `
            $fusedN5 `
            $outputDataset `
            $outputTiff

        if ($manifest) {
            "$($channel.Index)`t$($channel.Id)`t$($channel.Name)`t$outputDataset`t$outputTiff" |
                Add-Content -LiteralPath $manifest
        }
    }
}

function Invoke-FinalFusion() {
    $channels = @(Get-FusionChannels $datasetIsotropicXml)
    if ($channels.Count -eq 0) {
        throw "Cannot run final fusion because no channels were found in $datasetIsotropicXml"
    }

    $views = @(Get-RegisteredViewSetups $datasetIsotropicXml)
    foreach ($channel in $channels) {
        $channelViews = @($views | Where-Object { $_.ChannelId -eq $channel.Id } | Sort-Object Id)
        if ($channelViews.Count -eq 0) {
            throw "Cannot run final fusion for channel $($channel.Id) because no input views were found"
        }

        $args = @(
            "affine-fusion",
            "-o", (Convert-ToFileUri $fusedN5),
            "-s", "N5",
            "--localSparkBindAddress",
            "-f", "AVG_BLEND",
            "-t", "0",
            "-c", [string]$channel.Index
        )

        foreach ($view in $channelViews) {
            $args += @("-vi", ("0,{0}" -f $view.Id))
        }

        $args += @("--blockScale", "2,2,1")

        $fusionName = if ($channels.Count -eq 1) {
            "06_affine_fusion_isotropic"
        } else {
            "06_affine_fusion_ch$($channel.Id)_t0"
        }

        Invoke-SparkLogged $fusionName $args
    }
}

function Invoke-BigTiffOnlyCleanup() {
    if (-not $BigTiffOnlyOutput) {
        return
    }

    $channels = @(Get-FusionChannels $datasetIsotropicXml)
    $missingBigTiffs = @($channels | ForEach-Object {
        Get-FinalBigTiffOutputForChannel $_ $channels.Count
    } | Where-Object {
        -not (Test-Path -LiteralPath $_)
    })
    if ($missingBigTiffs.Count -gt 0) {
        throw "Refusing BigTIFF-only cleanup because fused BigTIFF output is missing: $($missingBigTiffs -join ', ')"
    }

    if ($SeparateViews -or $OnlySeparateViews) {
        $manifest = Join-Path $separateViewsRoot "registered_views_manifest.tsv"
        if (-not (Test-Path -LiteralPath $manifest)) {
            throw "Refusing BigTIFF-only cleanup because separate-views manifest is missing: $manifest"
        }
    }

    foreach ($path in @($fusedN5, $separateViewsN5, $rawN5, $fusionRawN5, $int16Dir, $fusionInt16Dir, $env:BIGSTITCHER_TMP)) {
        Remove-GeneratedPath $path
    }

    Write-PipelineStatus "COMPLETED bigtiff-only cleanup removed generated N5/mirror/tmp data after successful BigTIFF export"
}

function Invoke-SeparateViews() {
    if (-not (Test-Path -LiteralPath $datasetIsotropicXml)) {
        throw "Cannot export separate views because registered fusion XML is missing: $datasetIsotropicXml"
    }

    $views = @(Get-RegisteredViewSetups $datasetIsotropicXml)
    if ($views.Count -eq 0) {
        throw "No input ViewSetup entries found in $datasetIsotropicXml"
    }

    New-Item -ItemType Directory -Force -Path $separateViewsRoot | Out-Null
    Remove-GeneratedPath $separateViewsN5
    Remove-GeneratedPath $separateViewsXml
    if ($ExportBigTiff) {
        Remove-GeneratedPath $separateViewsBigTiffDir
        New-Item -ItemType Directory -Force -Path $separateViewsBigTiffDir | Out-Null
    }

    Invoke-SparkLogged "09_create_separate_views_container" @(
        "create-fusion-container",
        "-x", (Convert-ToFileUri $datasetIsotropicXml),
        "-o", (Convert-ToFileUri $separateViewsN5),
        "-s", "N5",
        "--bdv",
        "-xo", (Convert-ToFileUri $separateViewsXml),
        "-ch", [string]$views.Count,
        "-d", "UINT16",
        "--minIntensity", "0",
        "--maxIntensity", "65535",
        "-c", "Zstandard",
        "-cl", "1",
        "--blockSize", "128,128,128",
        "-ds", "1,1,1"
    )

    Set-BdvXmlN5RelativePath $separateViewsXml $separateViewsN5
    Set-BdvXmlVoxelSize $separateViewsXml
    Set-SeparateViewsXmlMetadata $separateViewsXml $views

    $manifest = Join-Path $separateViewsRoot "registered_views_manifest.tsv"
    "output_channel`tinput_setup_id`tinput_view_name`tn5_dataset`tbigtiff" |
        Set-Content -LiteralPath $manifest

    for ($i = 0; $i -lt $views.Count; $i++) {
        $view = $views[$i]
        $outputDataset = "setup$i/timepoint0/s0"
        $safeOutputName = "view_setup$($view.Id)_$($view.SafeName)_registered.tif"
        $viewTiff = Join-Path $separateViewsBigTiffDir $safeOutputName

        $separateViewArgs = @(
            "affine-fusion",
            "-o", (Convert-ToFileUri $separateViewsN5),
            "-s", "N5",
            "--localSparkBindAddress",
            "-f", "AVG_BLEND",
            "-t", "0",
            "-c", [string]$i,
            "--angleId", [string]$view.AngleId,
            "--channelId", [string]$view.ChannelId,
            "--illuminationId", [string]$view.IlluminationId,
            "--tileId", [string]$view.TileId,
            "--timepointId", "0",
            "--blockScale", "2,2,1"
        )

        Invoke-SparkLogged ("10_affine_separate_view_setup{0}" -f $view.Id) $separateViewArgs

        $blockCount = Get-N5DatasetBlockCount $separateViewsN5 $outputDataset
        if ($blockCount -eq 0) {
            Write-PipelineStatus (
                "WARNING separate view setup {0} wrote zero blocks with attribute filters; retrying with explicit ViewId" -f
                $view.Id
            )

            Invoke-SparkLogged ("10b_affine_separate_view_setup{0}_vi_retry" -f $view.Id) @(
                "affine-fusion",
                "-o", (Convert-ToFileUri $separateViewsN5),
                "-s", "N5",
                "--localSparkBindAddress",
                "-f", "AVG_BLEND",
                "-t", "0",
                "-c", [string]$i,
                "-vi", ("0,{0}" -f $view.Id),
                "--blockScale", "2,2,1"
            )

            $blockCount = Get-N5DatasetBlockCount $separateViewsN5 $outputDataset
            if ($blockCount -eq 0) {
                Write-PipelineStatus (
                    "WARNING separate view setup {0} still has zero blocks after explicit ViewId retry" -f
                    $view.Id
                )
                Invoke-SingleChannelSeparateViewFallback $view $i $outputDataset
                $blockCount = Get-N5DatasetBlockCount $separateViewsN5 $outputDataset
            }
        }

        Invoke-FusionSubtractForSetup ("10c_subtract_separate_view_setup{0}" -f $view.Id) $separateViewsN5 $i

        if ($ExportBigTiff) {
            Invoke-BigTiffDatasetExport `
                ("11_export_separate_view_setup{0}_bigtiff" -f $view.Id) `
                $separateViewsN5 `
                $outputDataset `
                $viewTiff
        }

        "$i`t$($view.Id)`t$($view.Name)`t$outputDataset`t$viewTiff" |
            Add-Content -LiteralPath $manifest
    }

    Write-PipelineStatus "COMPLETED separate views export"
}

$rawXml = Join-Path $datasetRoot "bdv.xml"
$mirrorScript = Join-Path $toolsRoot "create_bdv_int16_mirror.py"
$fusionXmlScript = Join-Path $toolsRoot "create_native_fusion_xml.py"
$mirrorSetupIds = Get-SetupIdsForChannelFilter $rawXml $ChannelIds
if ($mirrorSetupIds) {
    Write-PipelineStatus "CHANNEL FILTER ChannelIds=$ChannelIds setupIds=$mirrorSetupIds"
}

function Get-AcquisitionProfile([string]$xmlPath) {
    [xml]$doc = Get-Content -LiteralPath $xmlPath -Raw
    $setups = @($doc.SelectNodes("/SpimData/SequenceDescription/ViewSetups/ViewSetup"))
    $angleIds = @{}
    $tileIds = @{}
    foreach ($setup in $setups) {
        $attributes = $setup.SelectSingleNode("attributes")
        $angle = if ($attributes) { $attributes.SelectSingleNode("angle") } else { $null }
        $tile = if ($attributes) { $attributes.SelectSingleNode("tile") } else { $null }
        if ($angle -and $angle.InnerText.Trim()) { $angleIds[$angle.InnerText.Trim()] = $true }
        if ($tile -and $tile.InnerText.Trim()) { $tileIds[$tile.InnerText.Trim()] = $true }
    }
    [PSCustomObject]@{
        SetupCount = $setups.Count
        AngleCount = $angleIds.Count
        TileCount = $tileIds.Count
    }
}

# Resolve the acquisition profile: tiled (single angle, stage-positioned tiles) vs multiview
# (opposing / rotated views). Detection only fills defaults the caller did not explicitly override.
$acqProfile = Get-AcquisitionProfile $rawXml
$detectedType = if ($acqProfile.AngleCount -gt 1) { "multiview" } else { "tiled" }
$script:effectiveAcquisitionType = if ($AcquisitionType -eq "auto") { $detectedType } else { $AcquisitionType }
Write-PipelineStatus ("ACQUISITION setups={0} angles={1} tiles={2} detected={3} effective={4}" -f `
    $acqProfile.SetupCount, $acqProfile.AngleCount, $acqProfile.TileCount, $detectedType, $script:effectiveAcquisitionType)

if ($Sampling -eq "auto") {
    $Sampling = if ($script:effectiveAcquisitionType -eq "multiview") { "isotropic" } else { "anisotropic" }
}

$script:compareAngles = $false
if ($script:effectiveAcquisitionType -eq "multiview") {
    $script:compareAngles = $true
    if (-not $script:userSetFirstStackAsZero) { $FirstStackAsZero = $true }
    # tiles-as-angles is a STITCHING-only hack that makes --compareAngles pair views across tile IDs.
    # The interest-point path instead aligns across angles with --groupTiles, so only auto-enable it
    # for stitching.
    if ($RegistrationMode -eq "STITCHING" -and -not $script:userSetTilesAsAnglesReg -and $acqProfile.TileCount -gt 1) {
        $TilesAsAnglesReg = $true
    }
    if ($RegistrationMode -eq "STITCHING" -and $acqProfile.AngleCount -le 1) {
        Write-PipelineStatus "WARNING multiview requested but XML has <=1 angle attribute; --compareAngles cannot synthesize angle pairs. Consider -RegistrationMode INTERESTPOINTS for rotated/opposing views encoded without angle metadata."
    }
}
Write-PipelineStatus ("PROFILE sampling={0} compareAngles={1} tilesAsAnglesReg={2} firstStackAsZero={3} registrationMode={4} solverTm={5} solverRm={6}" -f `
    $Sampling, $script:compareAngles, [bool]$TilesAsAnglesReg, [bool]$FirstStackAsZero, $RegistrationMode, $SolverTransformModel, $SolverRegularizationModel)

if ($OnlySeparateViews) {
    Initialize-FusionVoxelSize
    Invoke-SeparateViews
    Invoke-BigTiffOnlyCleanup
    return
}

if ($OnlyExportBigTiff) {
    Initialize-FusionVoxelSize
    Invoke-BigTiffExport
    if ($SeparateViews) {
        Invoke-SeparateViews
    }
    Invoke-BigTiffOnlyCleanup
    Write-PipelineStatus "COMPLETED BigTIFF export"
    return
}

$mirrorArgs = @(
    $mirrorScript,
    "--source-xml", $rawXml,
    "--out", $int16Dir,
    "--workers", "2",
    "--block-z", "64",
    "--subtract", [string]$RegSubtract
)
if ($mirrorSetupIds) {
    $mirrorArgs += @("--setups", $mirrorSetupIds)
}
Invoke-PythonLogged "00_int16_mirror" $mirrorArgs

Remove-GeneratedPath $rawN5
Remove-GeneratedPath $fusionRawN5
Remove-GeneratedPath $datasetN5Xml
Remove-GeneratedPath $datasetFusionN5Xml
Remove-GeneratedPath $datasetIsotropicXml
Remove-GeneratedPath $fusedN5
Remove-GeneratedPath $fusedXml

Invoke-SparkLogged "01_resave_raw_multires_n5" @(
    "resave",
    "-x", (Convert-ToFileUri (Join-Path $int16Dir "dataset.xml")),
    "-xo", (Convert-ToFileUri $datasetN5Xml),
    "-o", (Convert-ToFileUri $rawN5),
    "--N5",
    "--localSparkBindAddress",
    "--blockSize", "128,128,64",
    "--blockScale", "8,8,1",
    "-ds", "1,1,1;2,2,1;4,4,2;8,8,4;16,16,8;32,32,16",
    "-c", "Zstandard",
    "-cl", "1"
)

Set-BdvXmlN5RelativePath $datasetN5Xml $rawN5
# tiles-as-angles rewriting only applies to the stitching path (it exists to make --compareAngles
# pair views that are split across tile IDs). In interest-point mode we keep the original tile IDs
# and align across angles via --groupTiles instead.
if ($RegistrationMode -eq "STITCHING") {
    Invoke-TilesAsAnglesRegistrationNormalization $datasetN5Xml
} elseif ($TilesAsAnglesReg) {
    Write-PipelineStatus "NOTE -TilesAsAnglesReg is ignored in INTERESTPOINTS mode; cross-angle alignment uses --groupTiles during matching/solving."
}
Set-DatasetN5XmlFamilyRelativePaths

Copy-Item -LiteralPath $datasetN5Xml -Destination (Join-Path $bdvXmlDir "dataset_n5.before_stitching.xml") -Force

if ($RegistrationMode -eq "INTERESTPOINTS") {
    # True affine registration path: detect Difference-of-Gaussian interest points, match them with
    # geometric hashing (many point correspondences per overlapping pair, RANSAC-filtered), then
    # solve a global affine model. This is the only path that can recover per-view rotation/shear.
    Write-PipelineStatus "REGISTRATION mode=INTERESTPOINTS label=$IpLabel method=$IpMatchMethod tm=$SolverTransformModel rm=$SolverRegularizationModel"
    Write-PipelineStatus "WARNING interest-point detection runs on the signed-int16 mirror; intensities above 32767 wrap negative. Ensure -IpMinIntensity/-IpMaxIntensity cover the signed range present in the data."

    $detectArgs = @(
        "detect-interestpoints",
        "-x", (Convert-ToFileUri $datasetN5Xml),
        "--localSparkBindAddress",
        "-l", $IpLabel,
        "-s", (Convert-ToInvariantString $IpSigma),
        "-t", (Convert-ToInvariantString $IpThreshold),
        "-dsxy", [string]$IpDownsampleXY,
        "-dsz", [string]$IpDownsampleZ,
        "--type", $IpType,
        "--minIntensity", $IpMinIntensity,
        "--maxIntensity", $IpMaxIntensity
    )
    if ($IpOverlappingOnly) { $detectArgs += "--overlappingOnly" }
    if ($IpMaxSpots -gt 0) { $detectArgs += @("--maxSpots", [string]$IpMaxSpots) }
    Invoke-SparkLogged "02a_detect_interestpoints" $detectArgs

    $matchArgs = @(
        "match-interestpoints",
        "-x", (Convert-ToFileUri $datasetN5Xml),
        "--localSparkBindAddress",
        "-l", $IpLabel,
        "-m", $IpMatchMethod,
        "-tm", $SolverTransformModel,
        "-rm", $SolverRegularizationModel,
        "--clearCorrespondences"
    )
    # For multiview data, group tiles of each angle into one view so matching aligns angle-to-angle.
    if ($script:effectiveAcquisitionType -eq "multiview") { $matchArgs += "--groupTiles" }
    Invoke-SparkLogged "02b_match_interestpoints" $matchArgs

    Set-DatasetN5XmlFamilyRelativePaths
    Copy-Item -LiteralPath $datasetN5Xml -Destination (Join-Path $bdvXmlDir "dataset_n5.before_solver.xml") -Force

    Invoke-SparkLogged "03_solver_interestpoints" @(
        "solver",
        "-x", (Convert-ToFileUri $datasetN5Xml),
        "--localSparkBindAddress",
        "-s", "IP",
        "-l", $IpLabel,
        "-tm", $SolverTransformModel,
        "-rm", $SolverRegularizationModel,
        "--method", "TWO_ROUND_ITERATIVE",
        "--maxError", "5.0"
    )

    if ($IpRefineICP) {
        # Optional fine-alignment refinement: ICP only works once the current transform is good.
        Set-DatasetN5XmlFamilyRelativePaths
        $icpMatchArgs = @(
            "match-interestpoints",
            "-x", (Convert-ToFileUri $datasetN5Xml),
            "--localSparkBindAddress",
            "-l", $IpLabel,
            "-m", "ICP",
            "-tm", $SolverTransformModel,
            "-rm", $SolverRegularizationModel,
            "--clearCorrespondences"
        )
        if ($script:effectiveAcquisitionType -eq "multiview") { $icpMatchArgs += "--groupTiles" }
        Invoke-SparkLogged "03e_match_interestpoints_icp" $icpMatchArgs

        Invoke-SparkLogged "03f_solver_interestpoints_icp" @(
            "solver",
            "-x", (Convert-ToFileUri $datasetN5Xml),
            "--localSparkBindAddress",
            "-s", "IP",
            "-l", $IpLabel,
            "-tm", $SolverTransformModel,
            "-rm", $SolverRegularizationModel,
            "--method", "TWO_ROUND_ITERATIVE",
            "--maxError", "5.0"
        )
    }
} else {
    $stitchArgs = @(
        "stitching",
        "-x", (Convert-ToFileUri $datasetN5Xml),
        "--localSparkBindAddress",
        "-ds", $StitchDownsampling,
        "-p", [string]$StitchPeaks,
        "--minR", (Convert-ToInvariantString $StitchMinR),
        "--maxR", (Convert-ToInvariantString $StitchMaxR)
    )
    if ($script:compareAngles) { $stitchArgs += "--compareAngles" }
    Invoke-SparkLogged "02_stitching_raw_multiview" $stitchArgs

    Set-DatasetN5XmlFamilyRelativePaths
    Copy-Item -LiteralPath $datasetN5Xml -Destination (Join-Path $bdvXmlDir "dataset_n5.before_solver.xml") -Force

    Invoke-SparkLogged "03_solver_raw_multiview" @(
        "solver",
        "-x", (Convert-ToFileUri $datasetN5Xml),
        "--localSparkBindAddress",
        "-s", "STITCHING",
        "-tm", $SolverTransformModel,
        "-rm", $SolverRegularizationModel,
        "--method", "ONE_ROUND_SIMPLE",
        "--maxError", "10.0"
    )
}

Set-DatasetN5XmlFamilyRelativePaths
Invoke-TransformQuantification `
    $datasetN5Xml `
    (Join-Path $bdvXmlDir "dataset_n5.before_solver.xml") `
    "registration_transform_quantification"

$fusionSourceXml = $datasetN5Xml
$fusionSourceN5 = $rawN5
if ($RegSubtract -gt 0) {
    Write-PipelineStatus "RESTORE-FOR-FUSION building un-subtracted fusion source after registration"
    $fusionMirrorArgs = @(
        $mirrorScript,
        "--source-xml", $rawXml,
        "--out", $fusionInt16Dir,
        "--workers", "2",
        "--block-z", "64",
        "--subtract", "0"
    )
    if ($mirrorSetupIds) {
        $fusionMirrorArgs += @("--setups", $mirrorSetupIds)
    }
    Invoke-PythonLogged "03c_int16_mirror_restored_for_fusion" $fusionMirrorArgs

    Remove-GeneratedPath $fusionRawN5
    Invoke-SparkLogged "03d_resave_restored_for_fusion_n5" @(
        "resave",
        "-x", (Convert-ToFileUri (Join-Path $fusionInt16Dir "dataset.xml")),
        "-xo", (Convert-ToFileUri $datasetFusionN5Xml),
        "-o", (Convert-ToFileUri $fusionRawN5),
        "--N5",
        "--localSparkBindAddress",
        "--blockSize", "128,128,64",
        "--blockScale", "8,8,1",
        "-ds", "1,1,1;2,2,1;4,4,2;8,8,4;16,16,8;32,32,16",
        "-c", "Zstandard",
        "-cl", "1"
    )

    Copy-Item -LiteralPath $datasetN5Xml -Destination $datasetFusionN5Xml -Force
    Set-BdvXmlN5RelativePath $datasetFusionN5Xml $fusionRawN5
    $fusionSourceXml = $datasetFusionN5Xml
    $fusionSourceN5 = $fusionRawN5
    Write-PipelineStatus "RESTORE-FOR-FUSION fusionSourceXml=$fusionSourceXml fusionSourceN5=$fusionSourceN5"
}

$fusionXmlArgs = @(
    $fusionXmlScript,
    $fusionSourceXml,
    $datasetIsotropicXml,
    "--sampling", $Sampling,
    "--metadata-json", $fusionMetadataJson
)
if ($FirstStackAsZero) {
    $fusionXmlArgs += "--first-stack-as-zero"
}
Invoke-PythonLogged "04_create_fusion_xml" $fusionXmlArgs

Set-BdvXmlN5RelativePath $datasetIsotropicXml $fusionSourceN5
Set-DatasetN5XmlFamilyRelativePaths
Initialize-FusionVoxelSize
$fusionChannels = @(Get-FusionChannels $datasetIsotropicXml)

Invoke-SparkLogged "05_create_isotropic_fusion_container" @(
    "create-fusion-container",
    "-x", (Convert-ToFileUri $datasetIsotropicXml),
    "-o", (Convert-ToFileUri $fusedN5),
    "-s", "N5",
    "--bdv",
    "-xo", (Convert-ToFileUri $fusedXml),
    "-tp", "1",
    "-ch", [string]$fusionChannels.Count,
    "-d", "UINT16",
    "--minIntensity", "0",
    "--maxIntensity", "65535",
    "-c", "Zstandard",
    "-cl", "1",
    "--blockSize", "128,128,128",
    "-ds", "1,1,1;2,2,2;4,4,4;8,8,8;16,16,16;32,32,32"
)

Set-BdvXmlN5RelativePath $fusedXml $fusedN5

if ($SeparateViews) {
    Invoke-SeparateViews
}

Invoke-FinalFusion
Invoke-FinalFusionSubtract

Set-BdvXmlVoxelSize $fusedXml
"Patched final fused XML voxelSize to $script:isotropicVoxelSize micrometer" |
    Set-Content -LiteralPath (Join-Path $logs "07_patch_final_voxel_size.log")
"0" | Set-Content -LiteralPath (Join-Path $logs "07_patch_final_voxel_size.exitcode") -NoNewline

if ($ExportBigTiff) {
    Invoke-BigTiffExport
}

Invoke-BigTiffOnlyCleanup

Write-PipelineStatus ("COMPLETED pipeline acquisition={0} sampling={1} registration={2}" -f $script:effectiveAcquisitionType, $Sampling, $RegistrationMode)
