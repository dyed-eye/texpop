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
lock="$root/vendor.lock"
mkdir -p "$vendor" "$katex" "$fonts"

katex_ver=
md_ver=

declare -A hashes=()
if [[ ! -f "$lock" ]]; then
  printf 'Missing vendor manifest: %s\n' "$lock" >&2
  exit 1
fi
while read -r kind key value _; do
  [[ -z "${kind:-}" || "$kind" == \#* ]] && continue
  case "$kind:$key" in
    version:katex) katex_ver="$value" ;;
    version:markdown-it) md_ver="$value" ;;
    hash:*) hashes["$key"]="$value" ;;
    *) printf 'Bad vendor manifest line: %s %s %s\n' "$kind" "$key" "$value" >&2; exit 1 ;;
  esac
done < "$lock"
if [[ -z "$katex_ver" || -z "$md_ver" ]]; then
  printf 'vendor.lock must define katex and markdown-it versions\n' >&2
  exit 1
fi
katex_cdn="https://cdn.jsdelivr.net/npm/katex@$katex_ver/dist"
md_cdn="https://cdn.jsdelivr.net/npm/markdown-it@$md_ver/dist"

if [[ "$no_verify" -eq 1 ]]; then
  printf 'WARNING: hash verification disabled. Use only for trusted vendor refreshes.\n' >&2
fi

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
    if ! curl -fsSL --max-redirs 3 "$url" -o "$dst"; then
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
