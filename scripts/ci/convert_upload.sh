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

sanitize_key() {
  python3 - <<'PY' "$1"
import sys

allowed = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.//")
text = sys.argv[1]
out = []
for ch in text:
    if ch in allowed:
        out.append(ch)
        continue
    code = ord(ch)
    if code <= 0xFFFF:
        out.append(f"_u{code:04X}_")
    else:
        out.append(f"_U{code:08X}_")
print("".join(out))
PY
}

upload_count=0
upload_failed=0

upload_file() {
  local file="$1"
  local rel_path="$2"
  local content_type="$3"
  local storage_rel_path
  local encoded_path
  local upload_url
  local response_file
  local http_status

  storage_rel_path="$(sanitize_key "$rel_path")"

  if [[ "$storage_rel_path" != "$rel_path" ]]; then
    echo "Sanitized key: $rel_path -> $storage_rel_path"
  fi

  if supabase storage cp "$file" "supabase://$SUPABASE_BUCKET_NAME/$storage_rel_path" --content-type "$content_type" --overwrite --project-ref "$project_ref" >/dev/null 2>&1; then
    upload_count=$((upload_count + 1))
    return 0
  fi

  encoded_path="$(urlencode "$storage_rel_path")"
  upload_url="$SUPABASE_PROJECT_URL/storage/v1/object/$SUPABASE_BUCKET_NAME/$encoded_path"

  response_file="$(mktemp)"
  http_status="$(curl -sS -o "$response_file" -w "%{http_code}" -X PUT \
    -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
    -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
    -H "Content-Type: $content_type" \
    --data-binary "@$file" \
    "$upload_url" || true)"

  if [[ "$http_status" == 2* ]]; then
    upload_count=$((upload_count + 1))
  else
    echo "$rel_path | status=$http_status | url=$upload_url | response=$(tr -d '\n' < "$response_file")" >> "$UPLOAD_LOG"
    upload_failed=$((upload_failed + 1))
  fi
  rm -f "$response_file"
}

while IFS= read -r -d '' file; do
  rel_path="${file#$OUT_DIR/}"
  upload_file "$file" "$rel_path" "image/avif"
done < <(find "$OUT_DIR" -type f -name "*.avif" -print0)

while IFS= read -r -d '' file; do
  rel_path="${file#./}"
  upload_file "$file" "$rel_path" "text/plain; charset=utf-8"
done < <(find . -type f -name "*.txt" -print0)

echo "Uploaded: $upload_count"
if [[ $upload_failed -gt 0 ]]; then
  echo "Upload failures: $upload_failed (see $UPLOAD_LOG)"
  echo "--- Upload failure details ---"
  cat "$UPLOAD_LOG"
fi
