#!/usr/bin/env bash
set -euo pipefail

# Apply retention policy on .backup/:
#   - today:                       keep ALL backups
#   - other days of current ISO week: keep only the latest per day
#   - older weeks:                 keep only the latest per ISO week (Mon-Sun)

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BACKUP_DIR="$ROOT/.backup"

if [ ! -d "$BACKUP_DIR" ]; then
  echo "no .backup/ folder, nothing to prune"
  exit 0
fi

# Portable date helpers (GNU coreutils and BSD/macOS).
iso_week_of() {
  local d="$1"  # YYYYMMDD
  if date -d "$d" +%G-%V >/dev/null 2>&1; then
    date -d "$d" +%G-%V
  else
    date -j -f "%Y%m%d" "$d" +%G-%V
  fi
}

iso_week_monday_of_today() {
  local dow delta
  dow="$(date +%u)"          # 1=Mon .. 7=Sun
  delta=$((dow - 1))
  if [ "$delta" -eq 0 ]; then
    date +%Y%m%d
  elif date -d "$delta days ago" +%Y%m%d >/dev/null 2>&1; then
    date -d "$delta days ago" +%Y%m%d
  else
    date -v -"$delta"d +%Y%m%d
  fi
}

TODAY="$(date +%Y%m%d)"
WEEK_START="$(iso_week_monday_of_today)"

BACKUPS="$(cd "$BACKUP_DIR" && ls -d -- */ 2>/dev/null \
  | sed 's#/$##' \
  | grep -E '^[0-9]{8}-[0-9]{6}$' \
  | sort -r || true)"

if [ -z "$BACKUPS" ]; then
  echo "no backups to evaluate"
  exit 0
fi

KEEP=" "
SEEN_DAYS=" "
SEEN_WEEKS=" "

for ts in $BACKUPS; do
  d="${ts%-*}"
  if [ "$d" = "$TODAY" ]; then
    KEEP="$KEEP$ts "
  elif [ "$d" -ge "$WEEK_START" ]; then
    case "$SEEN_DAYS" in
      *" $d "*) : ;;
      *) KEEP="$KEEP$ts "; SEEN_DAYS="$SEEN_DAYS$d " ;;
    esac
  else
    w="$(iso_week_of "$d")"
    case "$SEEN_WEEKS" in
      *" $w "*) : ;;
      *) KEEP="$KEEP$ts "; SEEN_WEEKS="$SEEN_WEEKS$w " ;;
    esac
  fi
done

PRUNED=0
for ts in $BACKUPS; do
  case "$KEEP" in
    *" $ts "*) : ;;
    *)
      echo "  - pruning $ts"
      rm -rf -- "$BACKUP_DIR/$ts"
      PRUNED=$((PRUNED + 1))
      ;;
  esac
done

KEPT="$(printf '%s\n' $KEEP | grep -c .)"
echo "retention: kept=$KEPT pruned=$PRUNED (today=$TODAY, week_start=$WEEK_START)"
