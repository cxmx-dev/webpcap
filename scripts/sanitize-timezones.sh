#!/usr/bin/env bash
# sanitize-timezones.sh — OPSEC: detect (default) or strip ( --fix ) timezone strings
# from public text files. Check-only by default; exits 1 when hits remain.
set -euo pipefail

FIX=0
ROOT="${1:-.}"
if [[ "${1:-}" == "--fix" ]]; then
  FIX=1
  ROOT="${2:-.}"
elif [[ "${1:-}" == "--check" ]]; then
  FIX=0
  ROOT="${2:-.}"
fi

# Always operate relative to ROOT
cd "$ROOT"

# Self + vendor exclusions (paths relative to ROOT)
EXCLUDE_GLOBS=(
  './scripts/sanitize-timezones.sh'
  './.github/workflows/timezone-sanitize.yml'
  './node_modules/*'
  './.git/*'
  './target/*'
  './dist/*'
  './build/*'
  './vendor/*'
  './.venv/*'
  './venv/*'
  './__pycache__/*'
  './concat/target/*'
  './engine/target/*'
)

# Public text-ish extensions + common changelog names
INCLUDE_EXT_REGEX='\.([Mm][Dd]|[Tt][Xx][Tt]|[Hh][Tt][Mm][Ll]?|[Jj][Ss]|[Tt][Ss][Xx]?|[Jj][Ss][Xx]?|[Jj][Ss][Oo][Nn]|[Yy][Aa]?[Mm][Ll]|[Tt][Oo][Mm][Ll]|[Rr][Ss]|[Pp][Ss]1|[Ss][Hh]|[Cc][Ss]|[Cc][Ss][Ss]|[Aa][Hh][Kk])$'
INCLUDE_NAME_REGEX='(NOTES|CHANGELOG|HISTORY|VERSION|RELEASES)(\.|$)'

# Timezone tokens (abbreviations + full names + UTC/GMT offsets)
# Does NOT match bare "UTC" alone (API names / DateTime.UtcNow); only UTC±N / GMT±N.
TZ_REGEX='(?i)\b(CST|CDT|EST|EDT|MST|MDT|PST|PDT)\b|(?i)\b(Central|Eastern|Mountain|Pacific)\s+(Standard|Daylight)\s+Time\b|(?i)\b(UTC|GMT)\s*[+-]\s*\d{1,2}(:\d{2})?\b'

is_excluded() {
  local f="$1"
  local g
  for g in "${EXCLUDE_GLOBS[@]}"; do
    # shellcheck disable=SC2254
    case "$f" in
      $g) return 0 ;;
    esac
  done
  # directory prefixes
  case "$f" in
    ./node_modules/*|./.git/*|./target/*|./dist/*|./build/*|./vendor/*|./.venv/*|./venv/*|*/__pycache__/*) return 0 ;;
  esac
  return 1
}

should_scan() {
  local f="$1" base
  base="$(basename "$f")"
  if [[ "$f" =~ $INCLUDE_EXT_REGEX ]]; then return 0; fi
  if [[ "$base" =~ $INCLUDE_NAME_REGEX ]]; then return 0; fi
  return 1
}

hits=0
files_hit=0
declare -a hit_files=()

# Prefer git-tracked files when in a repo (public surface only)
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  mapfile -t FILES < <(git ls-files -z | tr '\0' '\n')
else
  mapfile -t FILES < <(find . -type f ! -path './.git/*' 2>/dev/null)
fi

for f in "${FILES[@]}"; do
  [[ -z "$f" ]] && continue
  [[ "$f" != ./* && "$f" != /* ]] && f="./$f"
  is_excluded "$f" && continue
  should_scan "$f" || continue
  [[ -f "$f" ]] || continue

  if grep -nP "$TZ_REGEX" "$f" >/dev/null 2>&1; then
    files_hit=$((files_hit + 1))
    hit_files+=("$f")
    while IFS= read -r line; do
      hits=$((hits + 1))
      echo "$f:$line"
    done < <(grep -nP "$TZ_REGEX" "$f" 2>/dev/null || true)

    if [[ "$FIX" -eq 1 ]]; then
      # Keep clock time when present; drop zone tokens / full names / offsets
      # 1) strip full names
      # 2) strip UTC±N / GMT±N → UTC / GMT
      # 3) strip bare zone abbreviations (CST, etc.)
      tmp="$(mktemp)"
      # Use perl for reliable in-place unicode-safe rewrite
      perl -pe '
        s/\b(Central|Eastern|Mountain|Pacific)\s+(Standard|Daylight)\s+Time\b//gi;
        s/\b(UTC|GMT)\s*[+\-]\s*\d{1,2}(?::\d{2})?\b/$1/gi;
        s/\b(CST|CDT|EST|EDT|MST|MDT|PST|PDT)\b//gi;
        s/[ \t]{2,}/ /g;
        s/[ \t]+$//;
      ' "$f" > "$tmp"
      mv "$tmp" "$f"
    fi
  fi
done

echo ""
echo "timezone-sanitize: $hits hit(s) in $files_hit file(s) (root=$ROOT fix=$FIX)"

if [[ "$FIX" -eq 1 ]]; then
  # re-scan after fix
  remain=0
  for f in "${hit_files[@]:-}"; do
    [[ -f "$f" ]] || continue
    if grep -nP "$TZ_REGEX" "$f" >/dev/null 2>&1; then
      remain=$((remain + 1))
      echo "REMAIN: $f"
      grep -nP "$TZ_REGEX" "$f" || true
    fi
  done
  if [[ "$remain" -gt 0 ]]; then
    echo "timezone-sanitize: residual hits after --fix ($remain files)"
    exit 1
  fi
  echo "timezone-sanitize: fixed clean"
  exit 0
fi

if [[ "$hits" -gt 0 ]]; then
  echo "timezone-sanitize: FAIL (check-only). Re-run with --fix to rewrite, then review the diff."
  exit 1
fi

echo "timezone-sanitize: OK"
exit 0
