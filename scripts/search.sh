#!/usr/bin/env bash
# search.sh — ищет чанки в документе через TasK Chunks API.
# Один запрос за вызов. Агент ведёт поиск итеративно.
#
# Использование:
#   ./search.sh --source <UUID> --query "запрос"
#   ./search.sh --source-url <URL> --query "запрос"

set -euo pipefail

# ─── config ────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
load_task_environment

# ─── args ──────────────────────────────────────────

URL=""
SOURCE_UUID=""
PROJECT_UUID=""
QUERY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --source-url) [ $# -ge 2 ] || die "Для --source-url нужен URL"; URL="$2"; shift 2 ;;
    --source)     [ $# -ge 2 ] || die "Для --source нужен UUID"; SOURCE_UUID="$2"; shift 2 ;;
    --project)    [ $# -ge 2 ] || die "Для --project нужен UUID"; PROJECT_UUID="$2"; shift 2 ;;
    --query)      [ $# -ge 2 ] || die "Для --query нужен текст"; QUERY="$2"; shift 2 ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done

[ -z "$QUERY" ] && die "--query обязателен"

# ─── resolve source ────────────────────────────────

[ -z "$PROJECT_UUID" ] && [ -f "$PROJECT_FILE" ] && PROJECT_UUID=$(jq -r '.uuid // empty' "$PROJECT_FILE")
[ -z "$SOURCE_UUID" ] && [ -n "$URL" ] && SOURCE_UUID=$(cache_source_uuid "$(normalize_url "$URL")" "$URL")

[ -z "$PROJECT_UUID" ] && die "Не указан project (--project или .task_project.json)"
[ -z "$SOURCE_UUID" ]  && die "Не указан source (--source или --source-url)"

# ─── API wrapper ───────────────────────────────────

# ─── Search ────────────────────────────────────────

info "Поиск: «${QUERY}»"
RESULT=$(api_json POST "/projects/${PROJECT_UUID}/chunks/search" \
  "$(jq -n --arg q "$QUERY" --arg src "$SOURCE_UUID" '{query: $q, limit: 10, sourceUuids: [$src]}')") \
  || die "Не удалось выполнить поиск по чанкам"

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
