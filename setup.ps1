# setup.ps1 -- Download vendor files (KaTeX, markdown-it) into ./vendor/
# Re-run to refresh. Idempotent: skips files that already exist unless -Force.
#
# SECURITY: every downloaded file is verified against a pinned SHA-256 hash
# below. If jsDelivr serves a tampered or unexpectedly-changed file, the
# download is deleted and the script reports a failure. To upgrade vendor
# versions, bump $katexVer / $mdVer, run with -Force -NoVerifyHashes to
# fetch the new bytes, then update $expectedHashes from the
# `Get-FileHash vendor\... -Algorithm SHA256` output.

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

foreach ($d in @($vendor, $katex, $katexFnt)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}

$katexVer = '0.16.11'
$mdVer    = '14.1.0'
$katexCdn = "https://cdn.jsdelivr.net/npm/katex@$katexVer/dist"
$mdCdn    = "https://cdn.jsdelivr.net/npm/markdown-it@$mdVer/dist"

# Pinned SHA-256 hashes for each vendored file. Filenames are globally unique
# across the vendor/ tree so leaf name is sufficient as the lookup key. Update
# these whenever you bump $katexVer or $mdVer above.
$expectedHashes = @{
    'markdown-it.min.js'              = '38C70A1E7CA91AB40E2D9E6E60129851A717ED1C7D4ACBBDD41BF9503791CF68'
    'katex.min.css'                   = '717BC9AE7853B61F0F76455DDDF0ECD4F527A783F42DE2AC24684899C1C46258'
    'katex.min.js'                    = 'E6BFE5DEEBD4C7CCD272055BAB63BD3AB2C73B907B6E6A22D352740A81381FD4'
    'auto-render.min.js'              = '7B57D427AC6270677DAF8D8380DED2CC73336F9149A167B8E1FE0D6EF66604AE'
    'KaTeX_AMS-Regular.woff2'         = '0CDD387C9590A1A9F9794560022DBB59654A7D86F187AA0C81495AD42D3A7308'
    'KaTeX_Caligraphic-Bold.woff2'    = 'DE7701E42CF1F4CF0B766C03FB27977207EEE2F4FD5D76FA82188406DA43EA4C'
    'KaTeX_Caligraphic-Regular.woff2' = '5D53E70AD607C2352162DEC9E0923FB54ECDAFACCBF604CD8DCF7D00FACB989B'
    'KaTeX_Fraktur-Bold.woff2'        = '74444EFD593C005E3F4573B44524704C0AF0A937FE911CCA9E94068D0D140D3F'
    'KaTeX_Fraktur-Regular.woff2'     = '51814D270D06FF0255DBA0799994FA4D8C84D11F09951D47595F4ABB1F3602DC'
    'KaTeX_Main-Bold.woff2'           = '0F60D1B897938EC918C8CE073092411BAF9438F6739465693FF18B0F9D20B021'
    'KaTeX_Main-BoldItalic.woff2'     = '99CD42A3C072D918F2F44984A807CF7AA16E13545FD0875FC07C6C65F99E715B'
    'KaTeX_Main-Italic.woff2'         = '97479CA6CCE906ABC961ECAC96FAA5F9CA2E61B8E7670D475826BCDEE9A7C267'
    'KaTeX_Main-Regular.woff2'        = 'C2342CD8B869E01752A9321DC17213FC40D4D04C79688C1D43F2CF316ABD7866'
    'KaTeX_Math-BoldItalic.woff2'     = 'DC47344DBB6CB5B655C8460D561F4DF5F501B90C804AD3C6CEC65FE322351AB1'
    'KaTeX_Math-Italic.woff2'         = '7AF58C5EC8F132A2DDDE9027C6D7814DECCE4D3B822A11192A42A20E2E973264'
    'KaTeX_SansSerif-Bold.woff2'      = 'E99AE51144BF1232EFCC1BFE5ADD36262C6866B0FAAB24FA75740E1B98577A62'
    'KaTeX_SansSerif-Italic.woff2'    = '00B26AC825E2095056396E0553B8AC26D3F8AD158C3826E28B4C45B385C4714A'
    'KaTeX_SansSerif-Regular.woff2'   = '68E8C73EF42AFD3CCEC58BF0FBA302CCE448938E7FC020A5E31F8A952EEE1342'
    'KaTeX_Script-Regular.woff2'      = '036D4E95149B69FF9BCC0CD55771EFEB25FFA3947293E69ACD78D5AC328C684B'
    'KaTeX_Size1-Regular.woff2'       = '6B47C40166B6DBE21A5DFCA7718413F2147FD2399BE1BA605D8AD39CEDF25DFE'
    'KaTeX_Size2-Regular.woff2'       = 'D04C54219F9EAEC6D4D4FD42DFB28785975A4794D6B2FC71E566B9CD6DB842DD'
    'KaTeX_Size3-Regular.woff2'       = '73D591271B1604960CB10BB90FEE021670AF7297017E0E98480B332D11F51995'
    'KaTeX_Size4-Regular.woff2'       = 'A4AF7D414440A1C1790825CFB700CF9CF43B0F2C4B04F0EBC523011AD9853EC0'
    'KaTeX_Typewriter-Regular.woff2'  = '71D517D67827787CFABDF186914CC3358EDA539E37931941F2B2FD4A21F68C0B'
}

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
    $expected = $expectedHashes[$leaf]
    if (-not $expected) {
        Write-Warning ("No pinned hash for '{0}' -- skipping verification (update `$expectedHashes if you trust this file)" -f $leaf)
        continue
    }
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
