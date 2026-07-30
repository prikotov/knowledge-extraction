#!/usr/bin/env bash
# search.sh — ищет чанки в документе через TasK Chunks API.
# Один запрос за вызов. Агент ведёт поиск итеративно.
#
# Использование:
#   ./search.sh --source <UUID> --query "запрос"
#   ./search.sh --source-url <URL> --query "запрос"

set -euo pipefail

die() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[INFO]  $*" >&2; }

# ─── config ────────────────────────────────────────

TASK_API_URL="${TASK_API_URL:-https://api.ai-aid.pro/v1}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Ищем корень статьи: идём вверх, пока не найдём .task_project.json или .task_config.json
ARTICLE_DIR="$SCRIPT_DIR"
while [ "$ARTICLE_DIR" != "/" ] && [ ! -f "$ARTICLE_DIR/.task_project.json" ] && [ ! -f "$ARTICLE_DIR/.task_config.json" ]; do
  ARTICLE_DIR="$(dirname "$ARTICLE_DIR")"
done

if [ -f "$ARTICLE_DIR/.task_config.json" ]; then
  TASK_API_URL=$(jq -r '.api_url // empty' "$ARTICLE_DIR/.task_config.json")
fi
if [ -f "$ARTICLE_DIR/.task_token.json" ]; then
  TASK_API_TOKEN=$(jq -r '.access_token // empty' "$ARTICLE_DIR/.task_token.json")
else
  die ".task_token.json не найден. Создайте файл с access_token в корне проекта."
fi

# ─── args ──────────────────────────────────────────

URL=""
SOURCE_UUID=""
PROJECT_UUID=""
QUERY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --source-url) URL="$2"; shift 2 ;;
    --source)     SOURCE_UUID="$2"; shift 2 ;;
    --project)    PROJECT_UUID="$2"; shift 2 ;;
    --query)      QUERY="$2"; shift 2 ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done

[ -z "$QUERY" ] && die "--query обязателен"

# ─── resolve source ────────────────────────────────

PROJECT_FILE="$ARTICLE_DIR/.task_project.json"
normalize_url() { echo "$1" | sed -E 's|^https?://||; s|^www\.||; s|/+$||' | tr '[:upper:]' '[:lower:]'; }

[ -z "$PROJECT_UUID" ] && [ -f "$PROJECT_FILE" ] && PROJECT_UUID=$(jq -r '.uuid // empty' "$PROJECT_FILE")
[ -z "$SOURCE_UUID" ] && [ -n "$URL" ] && SOURCE_UUID=$(jq -r --arg url "$(normalize_url "$URL")" '.sources[$url].uuid // empty' "$PROJECT_FILE")

[ -z "$PROJECT_UUID" ] && die "Не указан project (--project или .task_project.json)"
[ -z "$SOURCE_UUID" ]  && die "Не указан source (--source или --source-url)"

# ─── API wrapper ───────────────────────────────────

api() {
  local method="$1" path="$2" data="${3:-}"
  local tmpfile http_code curl_rc
  tmpfile=$(mktemp)
  http_code=$(curl -sS -o "$tmpfile" -w "%{http_code}" \
    -X "$method" "${TASK_API_URL}${path}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $TASK_API_TOKEN" \
    ${data:+-d "$data"}) || curl_rc=$?
  cat "$tmpfile"; rm -f "$tmpfile"
  [ "${curl_rc:-0}" -ne 0 ] && return 1
  [ "$http_code" = "000" ] && return 1
  [ "$http_code" -ge 400 ] && return 1
  return 0
}

# ─── Search ────────────────────────────────────────

info "Поиск: «${QUERY}»"
RESULT=$(api POST "/projects/${PROJECT_UUID}/chunks/search" \
  "$(jq -n --arg q "$QUERY" --arg src "$SOURCE_UUID" '{query: $q, limit: 10, sourceUuids: [$src]}')") || true

CHUNKS=$(echo "$RESULT" | jq '.chunks // []')
CHUNK_COUNT=$(echo "$CHUNKS" | jq 'length')
info "Найдено чанков: $CHUNK_COUNT"

echo ""
echo "### ${QUERY}"
echo ""

if [ "$CHUNK_COUNT" -gt 0 ]; then
  echo "$CHUNKS" | jq -r '
    .[] | "**Чанк #\(.chunkNumber)**\n\n> \(.text)\n"
  '
else
  echo "_Чанки не найдены_"
fi
