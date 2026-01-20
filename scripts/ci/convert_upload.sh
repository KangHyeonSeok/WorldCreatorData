#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
OUT_DIR="${AVIF_OUT_DIR:-${RUNNER_TEMP:-/tmp}/avif-output}"
LOG_DIR="${AVIF_LOG_DIR:-${RUNNER_TEMP:-/tmp}/avif-logs}"

mkdir -p "$OUT_DIR" "$LOG_DIR"

CONVERT_LOG="$LOG_DIR/convert_failures.log"
UPLOAD_LOG="$LOG_DIR/upload_failures.log"

: > "$CONVERT_LOG"
: > "$UPLOAD_LOG"

AVIFENC_ARGS="${AVIFENC_ARGS:---min 20 --max 20 --speed 6}"

if [[ -z "${SUPABASE_PROJECT_URL:-}" || -z "${SUPABASE_SERVICE_ROLE_KEY:-}" || -z "${SUPABASE_BUCKET_NAME:-}" ]]; then
  echo "Missing required environment variables: SUPABASE_PROJECT_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_BUCKET_NAME" >&2
  exit 1
fi

cd "$ROOT_DIR"

converted_count=0
convert_failed=0

echo "Scanning for PNG files under: $ROOT_DIR"

while IFS= read -r -d '' file; do
  rel_path="${file#./}"
  out_path="$OUT_DIR/${rel_path%.*}.avif"

  mkdir -p "$(dirname "$out_path")"

  if avifenc $AVIFENC_ARGS "$file" "$out_path" >/dev/null 2>&1; then
    converted_count=$((converted_count + 1))
  else
    echo "$rel_path" >> "$CONVERT_LOG"
    convert_failed=$((convert_failed + 1))
    rm -f "$out_path"
  fi
done < <(find . -type f -name "*.png" -print0)

echo "Converted: $converted_count"
if [[ $convert_failed -gt 0 ]]; then
  echo "Convert failures: $convert_failed (see $CONVERT_LOG)"
fi

project_ref="$(echo "$SUPABASE_PROJECT_URL" | sed -E 's|https?://([^.]+).*|\1|')"

urlencode() {
  python3 - <<'PY' "$1"
import sys
import urllib.parse
print(urllib.parse.quote(sys.argv[1]))
PY
}

upload_count=0
upload_failed=0

while IFS= read -r -d '' file; do
  rel_path="${file#$OUT_DIR/}"

  if supabase storage cp "$file" "supabase://$SUPABASE_BUCKET_NAME/$rel_path" --content-type image/avif --overwrite --project-ref "$project_ref" >/dev/null 2>&1; then
    upload_count=$((upload_count + 1))
    continue
  fi

  encoded_path="$(urlencode "$rel_path")"
  upload_url="$SUPABASE_PROJECT_URL/storage/v1/object/$SUPABASE_BUCKET_NAME/$encoded_path"

  if curl -sS -X PUT \
    -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
    -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
    -H "Content-Type: image/avif" \
    --data-binary "@$file" \
    "$upload_url" \
    >/dev/null; then
    upload_count=$((upload_count + 1))
  else
    echo "$rel_path" >> "$UPLOAD_LOG"
    upload_failed=$((upload_failed + 1))
  fi
done < <(find "$OUT_DIR" -type f -name "*.avif" -print0)

echo "Uploaded: $upload_count"
if [[ $upload_failed -gt 0 ]]; then
  echo "Upload failures: $upload_failed (see $UPLOAD_LOG)"
fi
