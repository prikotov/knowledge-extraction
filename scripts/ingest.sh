#!/usr/bin/env bash
# ingest.sh — загружает материал в TasK, ждёт готовности.
# Создаёт/переиспользует проект и source, кеширует UUID в .task_project.json.
#
# Использование: ./ingest.sh --source-url <URL> [--project <UUID>]

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
PROJECT_UUID=""
CHECK_ONLY=false

while [ $# -gt 0 ]; do
  case "$1" in
    --source-url) URL="$2"; shift 2 ;;
    --project)    PROJECT_UUID="$2"; shift 2 ;;
    --check)      CHECK_ONLY=true; shift ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done
! $CHECK_ONLY && [ -z "$URL" ] && die "--source-url обязателен (или --check для проверки статусов)"

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

normalize_url() { echo "$1" | sed -E 's|^https?://||; s|^www\.||; s|/+$||' | tr '[:upper:]' '[:lower:]'; }

# ─── Check API ─────────────────────────────────────

if ! api GET "/projects" > /dev/null 2>&1; then
  die "TasK API недоступен"
fi

# ─── Project ───────────────────────────────────────

PROJECT_FILE="$ARTICLE_DIR/.task_project.json"
[ -f "$PROJECT_FILE" ] || echo '{"uuid":"","sources":{}}' > "$PROJECT_FILE"

[ -z "$PROJECT_UUID" ] && PROJECT_UUID=$(jq -r '.uuid // empty' "$PROJECT_FILE")

# Название проекта — имя папки статьи
PROJECT_TITLE=$(basename "$ARTICLE_DIR")

if [ -z "$PROJECT_UUID" ]; then
  info "Создаю проект: $PROJECT_TITLE"
  PROJECT_JSON=$(api POST "/projects" "{\"title\":\"$PROJECT_TITLE\",\"description\":\"Дайджест-подборка\"}") || true
  PROJECT_UUID=$(echo "$PROJECT_JSON" | jq -r '.uuid // empty')
  if [ -z "$PROJECT_UUID" ]; then
    info "Проект уже существует, ищу…"
    PROJECTS_JSON=$(api GET "/projects")
    PROJECT_UUID=$(echo "$PROJECTS_JSON" | jq -r --arg t "$PROJECT_TITLE" '.items[] | select(.title==$t) | .uuid // empty')
    [ -z "$PROJECT_UUID" ] && die "Не удалось найти или создать проект"
  fi
  jq --arg uuid "$PROJECT_UUID" '.uuid = $uuid' "$PROJECT_FILE" > "${PROJECT_FILE}.tmp" \
    && mv "${PROJECT_FILE}.tmp" "$PROJECT_FILE"
fi

info "Project: $PROJECT_UUID"

# ─── Режим --check: обновить статусы всех pending ────

if $CHECK_ONLY; then
  info "Проверяю статусы…"
  SOURCES_JSON=$(api GET "/projects/${PROJECT_UUID}/sources")
  UPDATED=0
  for url in $(jq -r '.sources | keys[]' "$PROJECT_FILE"); do
    SRC_UUID=$(jq -r --arg url "$url" '.sources[$url].uuid' "$PROJECT_FILE")
    NEW_STATUS=$(echo "$SOURCES_JSON" | jq -r --arg uuid "$SRC_UUID" \
      '.items[] | select(.uuid==$uuid) | .status // "unknown"')
    OLD_STATUS=$(jq -r --arg url "$url" '.sources[$url].status // "unknown"' "$PROJECT_FILE")
    if [ "$NEW_STATUS" != "$OLD_STATUS" ]; then
      jq --arg url "$url" --arg status "$NEW_STATUS" \
        '.sources[$url].status = $status' \
        "$PROJECT_FILE" > "${PROJECT_FILE}.tmp" && mv "${PROJECT_FILE}.tmp" "$PROJECT_FILE"
      echo "$url → $NEW_STATUS (был: $OLD_STATUS) ✦"
      UPDATED=$((UPDATED+1))
    else
      echo "$url → $NEW_STATUS"
    fi
  done
  echo "Изменений: $UPDATED"
  exit 0
fi

# ─── Source ────────────────────────────────────────

NORM_URL=$(normalize_url "$URL")
SOURCE_UUID=$(jq -r --arg url "$NORM_URL" '.sources[$url].uuid // empty' "$PROJECT_FILE")

if [ -z "$SOURCE_UUID" ]; then
  info "Ищу source в проекте…"
  SOURCES_JSON=$(api GET "/projects/${PROJECT_UUID}/sources")
  SOURCE_UUID=$(echo "$SOURCES_JSON" | jq -r --arg url "$NORM_URL" '
    .items[] | select(
      (.uri | sub("^https?://";"") | sub("^www\\.";"") | sub("/+$";"") | ascii_downcase) == $url
    ) | .uuid // empty
  ')
  if [ -n "$SOURCE_UUID" ]; then
    SRC_TITLE=$(echo "$SOURCES_JSON" | jq -r --arg url "$NORM_URL" '
      .items[] | select(
        (.uri | sub("^https?://";"") | sub("^www\\.";"") | sub("/+$";"") | ascii_downcase) == $url
      ) | .title // ""
    ')
    jq --arg url "$NORM_URL" --arg uuid "$SOURCE_UUID" --arg src_url "$URL" \
       --arg title "$SRC_TITLE" --arg date "$(date +%Y-%m-%d)" \
      '.sources[$url] = {"uuid":$uuid,"url":$src_url,"title":$title,"last_used":$date}' \
      "$PROJECT_FILE" > "${PROJECT_FILE}.tmp" && mv "${PROJECT_FILE}.tmp" "$PROJECT_FILE"
  fi
fi

if [ -z "$SOURCE_UUID" ]; then
  info "Загружаю: $URL"
  SOURCE_JSON=$(api POST "/projects/${PROJECT_UUID}/source-urls" "$(jq -n --arg url "$URL" '{uri: $url}')") || true
  SOURCE_UUID=$(echo "$SOURCE_JSON" | jq -r '.sourceUuid // empty')
  [ -z "$SOURCE_UUID" ] && die "Не удалось загрузить source"
  # Сохраняем в кеш
  jq --arg url "$NORM_URL" --arg uuid "$SOURCE_UUID" --arg src_url "$URL" \
     --arg date "$(date +%Y-%m-%d)" \
    '.sources[$url] = {"uuid":$uuid,"url":$src_url,"title":"","last_used":$date}' \
    "$PROJECT_FILE" > "${PROJECT_FILE}.tmp" && mv "${PROJECT_FILE}.tmp" "$PROJECT_FILE"
  info "Source создан: $SOURCE_UUID"
fi

info "Source: $SOURCE_UUID"

# ─── Wait ready ────────────────────────────────────

info "Ожидаю обработки…"
for i in $(seq 1 120); do
  SOURCES_JSON=$(api GET "/projects/${PROJECT_UUID}/sources")
  STATUS=$(echo "$SOURCES_JSON" | jq -r --arg uuid "$SOURCE_UUID" \
    '.items[] | select(.uuid==$uuid) | .status // "processing"')
  # Обновляем статус в кеше на каждой итерации
  jq --arg url "$NORM_URL" --arg status "$STATUS" \
    '.sources[$url].status = $status' \
    "$PROJECT_FILE" > "${PROJECT_FILE}.tmp" && mv "${PROJECT_FILE}.tmp" "$PROJECT_FILE"
  case "$STATUS" in
    ready)   info "✓ Готов (попытка $i)"; break ;;
    failed|error) die "Source в ошибке: $STATUS" ;;
    *)       sleep 5 ;;
  esac
  [ "$i" -eq 120 ] && die "Source не готов за 120 попыток (~10 мин). Статус: $STATUS. Проверьте позже через --check."
done

# ─── Output ────────────────────────────────────────

DOCS_JSON=$(api GET "/projects/${PROJECT_UUID}/sources/${SOURCE_UUID}/documents")
DOC_COUNT=$(echo "$DOCS_JSON" | jq '.items | length')

echo "project_uuid=$PROJECT_UUID"
echo "source_uuid=$SOURCE_UUID"
echo "documents=$DOC_COUNT"
echo "url=$URL"
