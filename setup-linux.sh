#!/usr/bin/env bash
# setup-linux.sh -- Download vendor files (KaTeX, markdown-it) into ./vendor/.
# Mirrors setup.ps1 on Windows. vendor.lock is the shared source of truth.
set -euo pipefail

force=0
no_verify=0
yes_no_verify=0
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    --no-verify-hashes) no_verify=1 ;;
    --yes-skip-verify) yes_no_verify=1 ;;
    -h|--help)
      printf 'Usage: %s [--force] [--no-verify-hashes [--yes-skip-verify]]\n' "$0"
      printf '  --force                refetch every file even if present\n'
      printf '  --no-verify-hashes     skip SHA-256 verification (DANGEROUS)\n'
      printf '  --yes-skip-verify      bypass interactive y/N confirmation for --no-verify-hashes\n'
      exit 0
      ;;
    *) printf 'Unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

# Precheck: sha256sum is the integrity gate. Surface a clear "tool not found"
# rather than letting the later hash check fail with "HASH MISMATCH" on a
# minimal container (e.g. busybox without coreutils).
if [[ "$no_verify" -ne 1 ]] && ! command -v sha256sum >/dev/null 2>&1; then
  printf 'setup-linux.sh: sha256sum not found in PATH; install coreutils or rerun with --no-verify-hashes.\n' >&2
  exit 1
fi

if [[ "$no_verify" -eq 1 ]]; then
  printf 'WARNING: hash verification disabled. Vendor files will be installed without integrity checking.\n' >&2
  if [[ "$yes_no_verify" -ne 1 ]]; then
    if [[ -t 0 ]]; then
      printf 'Type "yes" to continue: ' >&2
      read -r confirm
      if [[ "$confirm" != "yes" ]]; then
        printf 'Aborted.\n' >&2
        exit 1
      fi
    else
      printf 'Non-interactive shell; rerun with --yes-skip-verify to bypass the prompt.\n' >&2
      exit 1
    fi
  fi
fi

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
vendor="$root/vendor"
katex="$vendor/katex"
fonts="$katex/fonts"
lock="$root/vendor.lock"

# mkdir -p -m 0755 ensures the vendor tree isn't world-writable, closing the
# symlink-replacement TOCTOU window on multi-user systems.
mkdir -p -m 0755 "$vendor" "$katex" "$fonts"

# ---------- Parse vendor.lock ----------
# Shared format with setup.ps1; keep parsers in sync.
katex_ver=
md_ver=
declare -A hashes=()
font_names=()
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
    font:*) font_names+=("$key") ;;
    *) printf 'Bad vendor manifest line: %s %s %s\n' "$kind" "$key" "$value" >&2; exit 1 ;;
  esac
done < "$lock"
if [[ -z "$katex_ver" || -z "$md_ver" ]]; then
  printf 'vendor.lock must define katex and markdown-it versions\n' >&2
  exit 1
fi
if [[ "${#font_names[@]}" -eq 0 ]]; then
  printf 'vendor.lock must define at least one font\n' >&2
  exit 1
fi
katex_cdn="https://cdn.jsdelivr.net/npm/katex@$katex_ver/dist"
md_cdn="https://cdn.jsdelivr.net/npm/markdown-it@$md_ver/dist"

jobs=(
  "$md_cdn/markdown-it.min.js|$vendor/markdown-it.min.js"
  "$katex_cdn/katex.min.css|$katex/katex.min.css"
  "$katex_cdn/katex.min.js|$katex/katex.min.js"
  "$katex_cdn/contrib/auto-render.min.js|$katex/auto-render.min.js"
)
for name in "${font_names[@]}"; do
  jobs+=("$katex_cdn/fonts/$name.woff2|$fonts/$name.woff2")
done

# Atomic download helper: fetch to a temp file in the same directory, verify
# (if required), then atomic mv into place. Rejects symlink destinations -
# curl -o would otherwise follow the link and write through to an attacker
# target on multi-user systems.
fetch_and_install() {
  local url="$1" dst="$2" expected="${3:-}"
  if [[ -L "$dst" ]]; then
    printf 'Refusing to write through symlink: %s\n' "$dst" >&2
    return 1
  fi
  local dst_dir
  dst_dir="$(dirname -- "$dst")"
  local tmp
  tmp="$(mktemp -- "$dst_dir/.texpop-fetch.XXXXXX")"
  if ! curl -fsSL --max-redirs 3 "$url" -o "$tmp"; then
    rm -f -- "$tmp"
    printf 'Failed: %s\n' "$url" >&2
    return 1
  fi
  if [[ -n "$expected" ]]; then
    local actual
    actual="$(sha256sum "$tmp" | awk '{print toupper($1)}')"
    if [[ "$actual" != "$expected" ]]; then
      rm -f -- "$tmp"
      printf 'HASH MISMATCH for %s\nexpected: %s\nactual:   %s\n' \
        "$(basename "$dst")" "$expected" "$actual" >&2
      return 1
    fi
  fi
  chmod 0644 "$tmp"
  mv -f -- "$tmp" "$dst"
  return 0
}

i=0
failures=0
total=${#jobs[@]}
for job in "${jobs[@]}"; do
  i=$((i + 1))
  url="${job%%|*}"
  dst="${job#*|}"
  leaf="$(basename "$dst")"
  expected=""
  if [[ "$no_verify" -ne 1 ]]; then
    expected="${hashes[$leaf]:-}"
    if [[ -z "$expected" ]]; then
      printf 'No pinned hash for %s; update vendor.lock or rerun with --no-verify-hashes\n' "$leaf" >&2
      failures=$((failures + 1))
      continue
    fi
  fi
  if [[ -e "$dst" && ! -L "$dst" && "$force" -eq 0 ]]; then
    # File present; verify existing hash unless verification is disabled.
    if [[ "$no_verify" -ne 1 ]]; then
      actual="$(sha256sum "$dst" | awk '{print toupper($1)}')"
      if [[ "$actual" != "$expected" ]]; then
        printf '[%2d/%d] mismatch existing %s; refetching\n' "$i" "$total" "$leaf"
        if ! fetch_and_install "$url" "$dst" "$expected"; then
          failures=$((failures + 1))
        fi
      else
        printf '[%2d/%d] skip  %s\n' "$i" "$total" "$leaf"
      fi
    else
      printf '[%2d/%d] skip  %s\n' "$i" "$total" "$leaf"
    fi
    continue
  fi
  printf '[%2d/%d] fetch %s\n' "$i" "$total" "$leaf"
  if ! fetch_and_install "$url" "$dst" "$expected"; then
    failures=$((failures + 1))
  fi
done

if [[ "$failures" -gt 0 ]]; then
  printf 'Vendor setup completed with %d failure(s).\n' "$failures" >&2
  exit 1
fi
if [[ "$no_verify" -eq 1 ]]; then
  printf 'WARNING: vendor files installed without hash verification.\n' >&2
fi
printf 'Vendor files ready under: %s\n' "$vendor"
