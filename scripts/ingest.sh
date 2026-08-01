#!/usr/bin/env bash
# ingest.sh — загружает URL в TasK, ждёт готовности и кеширует UUID.
# Использование: ./ingest.sh --source-url <URL> [--project <UUID>]
#               ./ingest.sh --check [--project <UUID>]
set -euo pipefail

die() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[INFO]  $*" >&2; }
TASK_API_URL="${TASK_API_URL:-https://api.ai-aid.pro/v1}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTICLE_DIR="$SCRIPT_DIR"
while [ "$ARTICLE_DIR" != / ] && [ ! -f "$ARTICLE_DIR/.task_project.json" ] && [ ! -f "$ARTICLE_DIR/.task_config.json" ]; do ARTICLE_DIR="$(dirname "$ARTICLE_DIR")"; done
[ -f "$ARTICLE_DIR/.task_config.json" ] && TASK_API_URL=$(jq -r '.api_url // empty' "$ARTICLE_DIR/.task_config.json")
[ -f "$ARTICLE_DIR/.task_token.json" ] || die ".task_token.json не найден. Создайте файл с access_token в корне проекта."
TASK_API_TOKEN=$(jq -r '.access_token // empty' "$ARTICLE_DIR/.task_token.json")

URL=""; PROJECT_UUID=""; CHECK_ONLY=false
while [ $# -gt 0 ]; do
 case "$1" in
  --source-url) [ $# -ge 2 ] || die "Для --source-url нужен URL"; URL="$2"; shift 2 ;;
  --project) [ $# -ge 2 ] || die "Для --project нужен UUID"; PROJECT_UUID="$2"; shift 2 ;;
  --check) CHECK_ONLY=true; shift ;;
  *) die "Неизвестный аргумент: $1" ;;
 esac
done
! "$CHECK_ONLY" && [ -z "$URL" ] && die "--source-url обязателен (или --check для проверки статусов)"

# Successful response body goes to stdout. Every failure is safe diagnostic on stderr.
api() {
 local method="$1" path="$2" data="${3:-}" body headers code rc detail
 body=$(mktemp); headers=$(mktemp)
 if [ -n "$data" ]; then
  code=$(curl -sS -o "$body" -D "$headers" -w '%{http_code}' -X "$method" "${TASK_API_URL}${path}" -H 'Content-Type: application/json' -H "Authorization: Bearer $TASK_API_TOKEN" -d "$data" 2>/dev/null) || rc=$?
 else
  code=$(curl -sS -o "$body" -D "$headers" -w '%{http_code}' -X "$method" "${TASK_API_URL}${path}" -H 'Content-Type: application/json' -H "Authorization: Bearer $TASK_API_TOKEN" 2>/dev/null) || rc=$?
 fi
 if [ "${rc:-0}" -ne 0 ] || [ "$code" = 000 ]; then rm -f "$body" "$headers"; echo 'TasK API request failed.' >&2; return 1; fi
 if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
  detail=$(jq -r 'if type == "object" and (.detail | type == "string") then .detail else empty end' "$body" 2>/dev/null || true)
  if [ -n "$detail" ]; then echo "HTTP $code: $detail" >&2; else echo "HTTP $code: TasK API returned an unexpected error." >&2; fi
  rm -f "$body" "$headers"; return 1
 fi
 cat "$body"; rm -f "$body" "$headers"
}
normalize_url() { echo "$1" | sed -E 's|^https?://||; s|^www\.||; s|/+$||' | tr '[:upper:]' '[:lower:]'; }

# Retrieves every API page. The endpoint's pagination.total is the stop condition.
all_sources() {
 local offset=0 limit=100 total=-1 page count pages=()
 while :; do
  page=$(api GET "/projects/${PROJECT_UUID}/sources?limit=${limit}&offset=${offset}") || return 1
  pages+=("$page")
  count=$(jq '.items | length' <<<"$page")
  total=$(jq -r '.pagination.total // empty' <<<"$page")
  [[ "$total" =~ ^[0-9]+$ ]] || { echo 'TasK API returned invalid sources pagination.' >&2; return 1; }
  offset=$((offset + count))
  [ "$offset" -ge "$total" ] && break
  [ "$count" -gt 0 ] || { echo 'TasK API returned incomplete sources pagination.' >&2; return 1; }
 done
 printf '%s\n' "${pages[@]}" | jq -s '{items: [.[].items[]?]}'
}

api GET '/projects' >/dev/null || die 'TasK API недоступен'
PROJECT_FILE="$ARTICLE_DIR/.task_project.json"
[ -f "$PROJECT_FILE" ] || echo '{"uuid":"","sources":{}}' > "$PROJECT_FILE"
[ -z "$PROJECT_UUID" ] && PROJECT_UUID=$(jq -r '.uuid // empty' "$PROJECT_FILE")
PROJECT_TITLE=$(basename "$ARTICLE_DIR")
if [ -z "$PROJECT_UUID" ]; then
 info "Создаю проект: $PROJECT_TITLE"
 PROJECT_JSON=$(api POST '/projects' "$(jq -n --arg title "$PROJECT_TITLE" '{title:$title,description:"Дайджест-подборка"}')") || PROJECT_JSON=''
 PROJECT_UUID=$(jq -r '.uuid // empty' <<<"$PROJECT_JSON")
 if [ -z "$PROJECT_UUID" ]; then
  info 'Проект уже существует, ищу…'; PROJECTS_JSON=$(api GET /projects) || die 'Не удалось получить проекты'
  PROJECT_UUID=$(jq -r --arg t "$PROJECT_TITLE" '.items[] | select(.title==$t) | .uuid // empty' <<<"$PROJECTS_JSON" | head -n1)
  [ -n "$PROJECT_UUID" ] || die 'Не удалось найти или создать проект'
 fi
 jq --arg uuid "$PROJECT_UUID" '.uuid=$uuid' "$PROJECT_FILE" > "$PROJECT_FILE.tmp" && mv "$PROJECT_FILE.tmp" "$PROJECT_FILE"
fi
info "Project: $PROJECT_UUID"

# Merge by UUID. API fields only create missing records; existing custom fields survive.
merge_sources() {
 local sources="$1" imported=0 updated=0 encoded uuid uri title status old_status key existing key_base
 while IFS= read -r encoded; do
  [ -n "$encoded" ] || continue
  uuid=$(printf %s "$encoded" | base64 -d | jq -r '.uuid // empty'); [ -n "$uuid" ] || continue
  uri=$(printf %s "$encoded" | base64 -d | jq -r '.uri // .url // ""'); title=$(printf %s "$encoded" | base64 -d | jq -r '.title // ""'); status=$(printf %s "$encoded" | base64 -d | jq -r '.status // "unknown"')
  existing=$(jq -r --arg u "$uuid" '.sources | to_entries[]? | select(.value.uuid==$u) | .key' "$PROJECT_FILE" | head -n1)
  if [ -n "$existing" ]; then
   old_status=$(jq -r --arg k "$existing" '.sources[$k].status // "unknown"' "$PROJECT_FILE")
   jq --arg k "$existing" --arg s "$status" '.sources[$k].status=$s' "$PROJECT_FILE" > "$PROJECT_FILE.tmp" && mv "$PROJECT_FILE.tmp" "$PROJECT_FILE"
   if [ "$old_status" != "$status" ]; then echo "$existing → $status (был: $old_status) ✦"; updated=$((updated + 1)); fi
  else
   key_base=$(normalize_url "$uri"); key="$key_base"
   [ -n "$key" ] || key="$uuid"
   if jq -e --arg k "$key" '.sources[$k] != null' "$PROJECT_FILE" >/dev/null; then key="${key_base}#${uuid}"; fi
   jq --arg k "$key" --arg u "$uuid" --arg url "$uri" --arg title "$title" --arg status "$status" --arg date "$(date +%Y-%m-%d)" \
    '.sources[$k]={uuid:$u,url:$url,title:$title,status:$status,last_used:$date}' "$PROJECT_FILE" > "$PROJECT_FILE.tmp" && mv "$PROJECT_FILE.tmp" "$PROJECT_FILE"
   echo "$key → $status (импортирован из API)"; imported=$((imported + 1))
  fi
 done < <(jq -r '.items[] | @base64' <<<"$sources")
 MERGED_IMPORTED=$imported
 MERGED_UPDATED=$updated
}

if "$CHECK_ONLY"; then
 info 'Синхронизирую sources и проверяю статусы…'; SOURCES_JSON=$(all_sources) || die 'Не удалось получить sources'
 MERGED_IMPORTED=0; MERGED_UPDATED=0; merge_sources "$SOURCES_JSON"
 # Statuses are already merged; print every cached record, including API imports.
 jq -r '.sources | to_entries[] | "\(.key) → \(.value.status // "unknown")"' "$PROJECT_FILE"
 echo "Изменений: $((MERGED_UPDATED + MERGED_IMPORTED))"; exit 0
fi

NORM_URL=$(normalize_url "$URL")
SOURCE_UUID=$(jq -r --arg url "$NORM_URL" '.sources[$url].uuid // empty' "$PROJECT_FILE")
SOURCES_JSON=$(all_sources) || die 'Не удалось получить sources'
MERGED_IMPORTED=0; MERGED_UPDATED=0; merge_sources "$SOURCES_JSON" >/dev/null
if [ -z "$SOURCE_UUID" ]; then SOURCE_UUID=$(jq -r --arg url "$NORM_URL" '.items[] | select((.uri // "" | sub("^https?://";"") | sub("^www\\.";"") | sub("/+$";"") | ascii_downcase)==$url) | .uuid' <<<"$SOURCES_JSON" | head -n1); fi
if [ -z "$SOURCE_UUID" ]; then
 info "Загружаю: $URL"; SOURCE_JSON=$(api POST "/projects/${PROJECT_UUID}/source-urls" "$(jq -n --arg url "$URL" '{uri:$url}')") || die 'Не удалось загрузить source'
 SOURCE_UUID=$(jq -r '.sourceUuid // empty' <<<"$SOURCE_JSON"); [ -n "$SOURCE_UUID" ] || die 'Не удалось загрузить source'
 jq --arg url "$NORM_URL" --arg uuid "$SOURCE_UUID" --arg src_url "$URL" --arg date "$(date +%Y-%m-%d)" '.sources[$url]={uuid:$uuid,url:$src_url,title:"",status:"pending",last_used:$date}' "$PROJECT_FILE" > "$PROJECT_FILE.tmp" && mv "$PROJECT_FILE.tmp" "$PROJECT_FILE"
fi
info "Source: $SOURCE_UUID"
info 'Ожидаю обработки…'
for i in $(seq 1 120); do
 SOURCES_JSON=$(all_sources) || die 'Не удалось получить status source'; STATUS=$(jq -r --arg u "$SOURCE_UUID" '.items[] | select(.uuid==$u) | .status // "processing"' <<<"$SOURCES_JSON" | head -n1)
 jq --arg u "$SOURCE_UUID" --arg s "$STATUS" '.sources |= with_entries(if .value.uuid == $u then .value.status = $s else . end)' "$PROJECT_FILE" > "$PROJECT_FILE.tmp" && mv "$PROJECT_FILE.tmp" "$PROJECT_FILE"
 case "$STATUS" in ready) info "✓ Готов (попытка $i)"; break;; failed|error) die "Source в ошибке: $STATUS";; *) sleep 5;; esac
 [ "$i" -eq 120 ] && die "Source не готов за 120 попыток (~10 мин). Статус: $STATUS. Проверьте позже через --check."
done
DOCS_JSON=$(api GET "/projects/${PROJECT_UUID}/sources/${SOURCE_UUID}/documents") || die 'Не удалось получить documents'
echo "project_uuid=$PROJECT_UUID"; echo "source_uuid=$SOURCE_UUID"; echo "documents=$(jq '.items | length' <<<"$DOCS_JSON")"; echo "url=$URL"
