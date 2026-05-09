# setup.ps1 -- Download vendor files (KaTeX, markdown-it) into ./vendor/
# Re-run to refresh. Idempotent: skips files that already exist unless -Force.

[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$vendor    = Join-Path $root 'vendor'
$katex     = Join-Path $vendor 'katex'
$katexFnt  = Join-Path $katex 'fonts'

foreach ($d in @($vendor, $katex, $katexFnt)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}

$katexVer = '0.16.11'
$mdVer    = '14.1.0'
$katexCdn = "https://cdn.jsdelivr.net/npm/katex@$katexVer/dist"
$mdCdn    = "https://cdn.jsdelivr.net/npm/markdown-it@$mdVer/dist"

$jobs = @(
    @{ url = "$mdCdn/markdown-it.min.js";          dst = Join-Path $vendor 'markdown-it.min.js' },
    @{ url = "$katexCdn/katex.min.css";            dst = Join-Path $katex  'katex.min.css' },
    @{ url = "$katexCdn/katex.min.js";             dst = Join-Path $katex  'katex.min.js' },
    @{ url = "$katexCdn/contrib/auto-render.min.js"; dst = Join-Path $katex  'auto-render.min.js' }
)

$fonts = @(
    'KaTeX_AMS-Regular','KaTeX_Caligraphic-Bold','KaTeX_Caligraphic-Regular',
    'KaTeX_Fraktur-Bold','KaTeX_Fraktur-Regular',
    'KaTeX_Main-Bold','KaTeX_Main-BoldItalic','KaTeX_Main-Italic','KaTeX_Main-Regular',
    'KaTeX_Math-BoldItalic','KaTeX_Math-Italic',
    'KaTeX_SansSerif-Bold','KaTeX_SansSerif-Italic','KaTeX_SansSerif-Regular',
    'KaTeX_Script-Regular',
    'KaTeX_Size1-Regular','KaTeX_Size2-Regular','KaTeX_Size3-Regular','KaTeX_Size4-Regular',
    'KaTeX_Typewriter-Regular'
)
foreach ($f in $fonts) {
    $jobs += @{ url = "$katexCdn/fonts/$f.woff2"; dst = Join-Path $katexFnt "$f.woff2" }
}

$total = $jobs.Count
$i = 0
foreach ($j in $jobs) {
    $i++
    if ((Test-Path $j.dst) -and -not $Force) {
        Write-Host ("[{0,2}/{1}] skip  {2}" -f $i, $total, (Split-Path $j.dst -Leaf))
        continue
    }
    Write-Host ("[{0,2}/{1}] fetch {2}" -f $i, $total, (Split-Path $j.dst -Leaf))
    try {
        Invoke-WebRequest -Uri $j.url -OutFile $j.dst -UseBasicParsing
    } catch {
        Write-Warning ("Failed: {0}`n  -> {1}" -f $j.url, $_.Exception.Message)
    }
}

Write-Host ""
Write-Host "Vendor files ready under: $vendor" -ForegroundColor Green
