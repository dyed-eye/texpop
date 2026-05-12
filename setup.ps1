# setup.ps1 -- Download vendor files (KaTeX, markdown-it) into ./vendor/
# Re-run to refresh. Idempotent: skips files that already exist unless -Force.
#
# SECURITY: every downloaded file is verified against a pinned SHA-256 hash
# in vendor.lock. If jsDelivr serves a tampered or unexpectedly-changed file, the
# download is deleted and the script reports a failure. To upgrade vendor
# versions, bump vendor.lock, run with -Force -NoVerifyHashes to fetch the new
# bytes, then update vendor.lock from `Get-FileHash vendor\... -Algorithm SHA256`.

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$NoVerifyHashes
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$vendor    = Join-Path $root 'vendor'
$katex     = Join-Path $vendor 'katex'
$katexFnt  = Join-Path $katex 'fonts'
$lock      = Join-Path $root 'vendor.lock'

foreach ($d in @($vendor, $katex, $katexFnt)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}

$katexVer = $null
$mdVer    = $null
$expectedHashes = @{}
if (-not (Test-Path $lock)) {
    throw "Missing vendor manifest: $lock"
}
foreach ($line in Get-Content -LiteralPath $lock) {
    $trim = $line.Trim()
    if (-not $trim -or $trim.StartsWith('#')) { continue }
    $parts = $trim -split '\s+'
    if ($parts.Count -ge 3 -and $parts[0] -eq 'version' -and $parts[1] -eq 'katex') {
        $katexVer = $parts[2]
    } elseif ($parts.Count -ge 3 -and $parts[0] -eq 'version' -and $parts[1] -eq 'markdown-it') {
        $mdVer = $parts[2]
    } elseif ($parts[0] -eq 'hash' -and $parts.Count -ge 3) {
        $expectedHashes[$parts[1]] = $parts[2]
    } else {
        throw "Bad vendor manifest line: $line"
    }
}
if (-not $katexVer -or -not $mdVer) {
    throw 'vendor.lock must define katex and markdown-it versions'
}
if ($NoVerifyHashes) {
    Write-Warning 'Hash verification disabled. Use only for trusted vendor refreshes.'
}
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

$total    = $jobs.Count
$i        = 0
$failures = 0
foreach ($j in $jobs) {
    $i++
    $leaf = Split-Path $j.dst -Leaf
    $expected = $expectedHashes[$leaf]
    if (-not $NoVerifyHashes -and -not $expected) {
        throw ("FATAL: no pinned hash for {0} (vendor.lock incomplete)" -f $leaf)
    }
    if ((Test-Path $j.dst) -and -not $Force) {
        Write-Host ("[{0,2}/{1}] skip  {2}" -f $i, $total, $leaf)
    } else {
        Write-Host ("[{0,2}/{1}] fetch {2}" -f $i, $total, $leaf)
        try {
            Invoke-WebRequest -Uri $j.url -OutFile $j.dst -UseBasicParsing
        } catch {
            Write-Warning ("Failed: {0}`n  -> {1}" -f $j.url, $_.Exception.Message)
            $failures++
            continue
        }
    }
    if ($NoVerifyHashes) { continue }
    if (-not (Test-Path $j.dst)) { continue }
    $actual = (Get-FileHash -Path $j.dst -Algorithm SHA256).Hash
    if ($actual -ne $expected) {
        Write-Warning ("HASH MISMATCH for '{0}'`n  expected: {1}`n  actual:   {2}`n  Deleting tampered/unexpected file. Re-run after investigating, or use -NoVerifyHashes to override." -f $leaf, $expected, $actual)
        try { Remove-Item -LiteralPath $j.dst -Force -ErrorAction SilentlyContinue } catch { }
        $failures++
    }
}

Write-Host ""
if ($failures -gt 0) {
    Write-Host ("Vendor setup completed with {0} failure(s). See warnings above." -f $failures) -ForegroundColor Yellow
    exit 1
}
Write-Host "Vendor files ready under: $vendor" -ForegroundColor Green
