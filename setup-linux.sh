#!/usr/bin/env bash
set -euo pipefail

force=0
no_verify=0
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    --no-verify-hashes) no_verify=1 ;;
    -h|--help)
      printf 'Usage: %s [--force] [--no-verify-hashes]\n' "$0"
      exit 0
      ;;
    *) printf 'Unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
vendor="$root/vendor"
katex="$vendor/katex"
fonts="$katex/fonts"
mkdir -p "$vendor" "$katex" "$fonts"

katex_ver=0.16.11
md_ver=14.1.0
katex_cdn="https://cdn.jsdelivr.net/npm/katex@$katex_ver/dist"
md_cdn="https://cdn.jsdelivr.net/npm/markdown-it@$md_ver/dist"

declare -A hashes=(
  [markdown-it.min.js]=38C70A1E7CA91AB40E2D9E6E60129851A717ED1C7D4ACBBDD41BF9503791CF68
  [katex.min.css]=717BC9AE7853B61F0F76455DDDF0ECD4F527A783F42DE2AC24684899C1C46258
  [katex.min.js]=E6BFE5DEEBD4C7CCD272055BAB63BD3AB2C73B907B6E6A22D352740A81381FD4
  [auto-render.min.js]=7B57D427AC6270677DAF8D8380DED2CC73336F9149A167B8E1FE0D6EF66604AE
  [KaTeX_AMS-Regular.woff2]=0CDD387C9590A1A9F9794560022DBB59654A7D86F187AA0C81495AD42D3A7308
  [KaTeX_Caligraphic-Bold.woff2]=DE7701E42CF1F4CF0B766C03FB27977207EEE2F4FD5D76FA82188406DA43EA4C
  [KaTeX_Caligraphic-Regular.woff2]=5D53E70AD607C2352162DEC9E0923FB54ECDAFACCBF604CD8DCF7D00FACB989B
  [KaTeX_Fraktur-Bold.woff2]=74444EFD593C005E3F4573B44524704C0AF0A937FE911CCA9E94068D0D140D3F
  [KaTeX_Fraktur-Regular.woff2]=51814D270D06FF0255DBA0799994FA4D8C84D11F09951D47595F4ABB1F3602DC
  [KaTeX_Main-Bold.woff2]=0F60D1B897938EC918C8CE073092411BAF9438F6739465693FF18B0F9D20B021
  [KaTeX_Main-BoldItalic.woff2]=99CD42A3C072D918F2F44984A807CF7AA16E13545FD0875FC07C6C65F99E715B
  [KaTeX_Main-Italic.woff2]=97479CA6CCE906ABC961ECAC96FAA5F9CA2E61B8E7670D475826BCDEE9A7C267
  [KaTeX_Main-Regular.woff2]=C2342CD8B869E01752A9321DC17213FC40D4D04C79688C1D43F2CF316ABD7866
  [KaTeX_Math-BoldItalic.woff2]=DC47344DBB6CB5B655C8460D561F4DF5F501B90C804AD3C6CEC65FE322351AB1
  [KaTeX_Math-Italic.woff2]=7AF58C5EC8F132A2DDDE9027C6D7814DECCE4D3B822A11192A42A20E2E973264
  [KaTeX_SansSerif-Bold.woff2]=E99AE51144BF1232EFCC1BFE5ADD36262C6866B0FAAB24FA75740E1B98577A62
  [KaTeX_SansSerif-Italic.woff2]=00B26AC825E2095056396E0553B8AC26D3F8AD158C3826E28B4C45B385C4714A
  [KaTeX_SansSerif-Regular.woff2]=68E8C73EF42AFD3CCEC58BF0FBA302CCE448938E7FC020A5E31F8A952EEE1342
  [KaTeX_Script-Regular.woff2]=036D4E95149B69FF9BCC0CD55771EFEB25FFA3947293E69ACD78D5AC328C684B
  [KaTeX_Size1-Regular.woff2]=6B47C40166B6DBE21A5DFCA7718413F2147FD2399BE1BA605D8AD39CEDF25DFE
  [KaTeX_Size2-Regular.woff2]=D04C54219F9EAEC6D4D4FD42DFB28785975A4794D6B2FC71E566B9CD6DB842DD
  [KaTeX_Size3-Regular.woff2]=73D591271B1604960CB10BB90FEE021670AF7297017E0E98480B332D11F51995
  [KaTeX_Size4-Regular.woff2]=A4AF7D414440A1C1790825CFB700CF9CF43B0F2C4B04F0EBC523011AD9853EC0
  [KaTeX_Typewriter-Regular.woff2]=71D517D67827787CFABDF186914CC3358EDA539E37931941F2B2FD4A21F68C0B
)

jobs=(
  "$md_cdn/markdown-it.min.js|$vendor/markdown-it.min.js"
  "$katex_cdn/katex.min.css|$katex/katex.min.css"
  "$katex_cdn/katex.min.js|$katex/katex.min.js"
  "$katex_cdn/contrib/auto-render.min.js|$katex/auto-render.min.js"
)

font_names=(
  KaTeX_AMS-Regular KaTeX_Caligraphic-Bold KaTeX_Caligraphic-Regular
  KaTeX_Fraktur-Bold KaTeX_Fraktur-Regular
  KaTeX_Main-Bold KaTeX_Main-BoldItalic KaTeX_Main-Italic KaTeX_Main-Regular
  KaTeX_Math-BoldItalic KaTeX_Math-Italic
  KaTeX_SansSerif-Bold KaTeX_SansSerif-Italic KaTeX_SansSerif-Regular
  KaTeX_Script-Regular
  KaTeX_Size1-Regular KaTeX_Size2-Regular KaTeX_Size3-Regular KaTeX_Size4-Regular
  KaTeX_Typewriter-Regular
)
for name in "${font_names[@]}"; do
  jobs+=("$katex_cdn/fonts/$name.woff2|$fonts/$name.woff2")
done

i=0
failures=0
total=${#jobs[@]}
for job in "${jobs[@]}"; do
  i=$((i + 1))
  url="${job%%|*}"
  dst="${job#*|}"
  leaf="$(basename "$dst")"
  if [[ -f "$dst" && "$force" -eq 0 ]]; then
    printf '[%2d/%d] skip  %s\n' "$i" "$total" "$leaf"
  else
    printf '[%2d/%d] fetch %s\n' "$i" "$total" "$leaf"
    if ! curl -fsSL "$url" -o "$dst"; then
      printf 'Failed: %s\n' "$url" >&2
      failures=$((failures + 1))
      continue
    fi
  fi
  [[ "$no_verify" -eq 1 ]] && continue
  expected="${hashes[$leaf]:-}"
  if [[ -z "$expected" ]]; then
    printf 'No pinned hash for %s\n' "$leaf" >&2
    continue
  fi
  actual="$(sha256sum "$dst" | awk '{print toupper($1)}')"
  if [[ "$actual" != "$expected" ]]; then
    printf 'HASH MISMATCH for %s\nexpected: %s\nactual:   %s\n' "$leaf" "$expected" "$actual" >&2
    rm -f "$dst"
    failures=$((failures + 1))
  fi
done

if [[ "$failures" -gt 0 ]]; then
  printf 'Vendor setup completed with %d failure(s).\n' "$failures" >&2
  exit 1
fi
printf 'Vendor files ready under: %s\n' "$vendor"
