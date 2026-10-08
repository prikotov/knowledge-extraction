#!/usr/bin/env bash
# ingest.sh — загружает URL в TasK, ждёт готовности и кеширует UUID.
# Использование: ./ingest.sh (--source-url <URL> | --source-file <path>) [--project <UUID>]
#               ./ingest.sh --check [--project <UUID>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
load_task_environment

URL=""; SOURCE_FILE=""; PROJECT_UUID=""; PROJECT_NAME_ARG=""; PROJECT_DESC_ARG=""; CHECK_ONLY=false
while [ $# -gt 0 ]; do
 case "$1" in
  --source-url) [ $# -ge 2 ] || die "Для --source-url нужен URL"; URL="$2"; shift 2 ;;
  --source-file) [ $# -ge 2 ] || die "Для --source-file нужен путь"; SOURCE_FILE="$2"; shift 2 ;;
  --project) [ $# -ge 2 ] || die "Для --project нужен UUID"; PROJECT_UUID="$2"; shift 2 ;;
  --project-name) [ $# -ge 2 ] || die "Для --project-name нужно имя"; PROJECT_NAME_ARG="$2"; shift 2 ;;
  --project-description) [ $# -ge 2 ] || die "Для --project-description нужен текст"; PROJECT_DESC_ARG="$2"; shift 2 ;;
  --check) CHECK_ONLY=true; shift ;;
  *) die "Неизвестный аргумент: $1" ;;
 esac
done
if [ -n "$URL" ] && [ -f "$URL" ] && [ -z "$SOURCE_FILE" ]; then SOURCE_FILE="$URL"; URL=""; fi
[ -n "$SOURCE_FILE" ] && [ ! -f "$SOURCE_FILE" ] && die "Файл не найден: $SOURCE_FILE"
[ -n "$URL" ] && [ -n "$SOURCE_FILE" ] && die "Укажите только --source-url или --source-file"
! "$CHECK_ONLY" && [ -z "$URL" ] && [ -z "$SOURCE_FILE" ] && die "Нужен --source-url или --source-file (или --check)"

api_file() {
 local path="$1" file="$2" body headers code rc detail
 body=$(mktemp); headers=$(mktemp)
 code=$(curl -sS --connect-timeout 10 --max-time 600 -o "$body" -D "$headers" -w '%{http_code}' -X POST "${TASK_API_URL}${path}" -H "Authorization: Bearer $TASK_API_TOKEN" -F "file=@${file}" 2>/dev/null) || rc=$?
 if [ "${rc:-0}" -ne 0 ] || [ "$code" = 000 ]; then rm -f "$body" "$headers"; echo 'TasK API request failed.' >&2; return 1; fi
 if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
  detail=$(jq -r 'if type == "object" and (.detail | type == "string") then .detail else empty end' "$body" 2>/dev/null || true)
  if [ -n "$detail" ]; then echo "HTTP $code: $detail" >&2; else echo "HTTP $code: TasK API returned an unexpected error." >&2; fi
  rm -f "$body" "$headers"; return 1
 fi
 cat "$body"; rm -f "$body" "$headers"
}

# Retrieves every API page. The endpoint's pagination.total is the stop condition.
all_sources() {
 local offset=0 limit=100 total=-1 page count pages=()
 while :; do
  page=$(api_json GET "/projects/${PROJECT_UUID}/sources?limit=${limit}&offset=${offset}") || return 1
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

"$CHECK_ONLY" && [ ! -f "$PROJECT_FILE" ] && [ -z "$PROJECT_UUID" ] \
  && die "Для --check нужен существующий .task_project.json или --project"
state_migrate "$PROJECT_FILE"
PROJECT_NAME=$(resolve_project_name "$PROJECT_NAME_ARG")
api_json GET '/projects' >/dev/null || die 'TasK API недоступен'
[ -f "$PROJECT_FILE" ] || echo '{"active":"","projects":{}}' > "$PROJECT_FILE"
CACHED_PROJECT_UUID=$(jq -r --arg n "$PROJECT_NAME" '.projects[$n].uuid // empty' "$PROJECT_FILE")
if [ -n "$PROJECT_UUID" ] && [ -n "$CACHED_PROJECT_UUID" ] && [ "$PROJECT_UUID" != "$CACHED_PROJECT_UUID" ]; then
 die "--project не совпадает с UUID проекта «$PROJECT_NAME» в .task_project.json"
fi
[ -z "$PROJECT_UUID" ] && PROJECT_UUID="$CACHED_PROJECT_UUID"
"$CHECK_ONLY" && [ -z "$PROJECT_UUID" ] && die "Для --check нужен существующий .task_project.json или --project"
if [ "$PROJECT_NAME" = "default" ]; then PROJECT_TITLE=$(basename "$ARTICLE_DIR"); else PROJECT_TITLE="$PROJECT_NAME"; fi
if [ -n "$PROJECT_UUID" ]; then
 jq --arg n "$PROJECT_NAME" --arg uuid "$PROJECT_UUID" --arg t "$PROJECT_TITLE" --arg d "$PROJECT_DESC_ARG" '(.projects[$n].sources //= {}) | .projects[$n].uuid=$uuid | .projects[$n].title=$t | (if $d != "" then .projects[$n].description=$d else . end) | .active=$n' "$PROJECT_FILE" > "$PROJECT_FILE.tmp" && mv "$PROJECT_FILE.tmp" "$PROJECT_FILE"
else
 info "Создаю проект: $PROJECT_TITLE"
 PROJECT_DESCRIPTION="${PROJECT_DESC_ARG:-Материалы для извлечения знаний}"
 PROJECT_JSON=$(api_json POST '/projects' "$(jq -n --arg title "$PROJECT_TITLE" --arg d "$PROJECT_DESCRIPTION" '{title:$title,description:$d}')") \
   || die 'Не удалось создать проект'
 PROJECT_UUID=$(jq -r '.uuid // empty' <<<"$PROJECT_JSON")
 if [ -z "$PROJECT_UUID" ]; then
  info 'Проект уже существует, ищу…'
  PROJECTS_JSON=$(api_json GET /projects) || die 'Не удалось получить проекты'
  PROJECT_UUID=$(jq -r --arg t "$PROJECT_TITLE" '.items[] | select(.title==$t) | .uuid // empty' <<<"$PROJECTS_JSON" | head -n1)
  [ -n "$PROJECT_UUID" ] || die 'TasK API не вернул UUID созданного проекта'
 fi
 jq --arg n "$PROJECT_NAME" --arg uuid "$PROJECT_UUID" --arg t "$PROJECT_TITLE" --arg d "$PROJECT_DESC_ARG" '(.projects[$n].sources //= {}) | .projects[$n].uuid=$uuid | .projects[$n].title=$t | (if $d != "" then .projects[$n].description=$d else . end) | .active=$n' "$PROJECT_FILE" > "$PROJECT_FILE.tmp" && mv "$PROJECT_FILE.tmp" "$PROJECT_FILE"
fi
info "Проект: $PROJECT_TITLE ($PROJECT_UUID)"
[ -n "$PROJECT_DESC_ARG" ] && info "Назначение: $PROJECT_DESC_ARG"
info "Рабочий каталог: $ARTICLE_DIR"

# Merge by UUID. API fields only create missing records; existing custom fields survive.
merge_sources() {
 local sources="$1" imported=0 updated=0 encoded uuid uri title status old_status key existing key_base
 while IFS= read -r encoded; do
  [ -n "$encoded" ] || continue
  uuid=$(printf %s "$encoded" | base64 -d | jq -r '.uuid // empty'); [ -n "$uuid" ] || continue
  uri=$(printf %s "$encoded" | base64 -d | jq -r '.uri // .url // ""'); title=$(printf %s "$encoded" | base64 -d | jq -r '.title // ""'); status=$(printf %s "$encoded" | base64 -d | jq -r '.preparationStatus // .status // "unknown"')
  existing=$(jq -r --arg n "$PROJECT_NAME" --arg u "$uuid" '(.projects[$n].sources // {}) | to_entries[]? | select(.value.uuid==$u) | .key' "$PROJECT_FILE" | head -n1)
  if [ -n "$existing" ]; then
   old_status=$(jq -r --arg n "$PROJECT_NAME" --arg k "$existing" '.projects[$n].sources[$k].status // "unknown"' "$PROJECT_FILE")
   jq --arg n "$PROJECT_NAME" --arg k "$existing" --arg s "$status" '.projects[$n].sources[$k].status=$s' "$PROJECT_FILE" > "$PROJECT_FILE.tmp" && mv "$PROJECT_FILE.tmp" "$PROJECT_FILE"
   if [ "$old_status" != "$status" ]; then echo "$existing → $status (был: $old_status) ✦"; updated=$((updated + 1)); fi
  else
   key_base=$(normalize_url "$uri"); key="$key_base"
   [ -n "$key" ] || key="$uuid"
   if jq -e --arg n "$PROJECT_NAME" --arg k "$key" '.projects[$n].sources[$k] != null' "$PROJECT_FILE" >/dev/null; then key="${key_base}#${uuid}"; fi
   jq --arg n "$PROJECT_NAME" --arg k "$key" --arg u "$uuid" --arg url "$uri" --arg title "$title" --arg status "$status" --arg date "$(date +%Y-%m-%d)" \
    '.projects[$n].sources[$k]={uuid:$u,url:$url,title:$title,status:$status,last_used:$date}' "$PROJECT_FILE" > "$PROJECT_FILE.tmp" && mv "$PROJECT_FILE.tmp" "$PROJECT_FILE"
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
 jq -r --arg n "$PROJECT_NAME" '.projects[$n].sources | to_entries[] | "\(.key) → \(.value.status // "unknown")"' "$PROJECT_FILE"
 echo "Изменений: $((MERGED_UPDATED + MERGED_IMPORTED))"; exit 0
fi

if [ -n "$SOURCE_FILE" ]; then SOURCE_VALUE=$(canonical_file "$SOURCE_FILE"); NORM_URL="$SOURCE_VALUE"; else SOURCE_VALUE="$URL"; NORM_URL=$(normalize_url "$URL"); fi
SOURCE_UUID=$(cache_source_uuid "$NORM_URL" "$SOURCE_VALUE")
SOURCES_JSON=$(all_sources) || die 'Не удалось получить sources'
MERGED_IMPORTED=0; MERGED_UPDATED=0; merge_sources "$SOURCES_JSON" >/dev/null
SOURCE_UUID=$(cache_source_uuid "$NORM_URL" "$SOURCE_VALUE")
if [ -z "$SOURCE_UUID" ] && [ -z "$SOURCE_FILE" ]; then SOURCE_UUID=$(jq -r --arg url "$URL" '.items[] | select((.uri // .url // "") == $url) | .uuid' <<<"$SOURCES_JSON" | head -n1); fi
if [ -z "$SOURCE_UUID" ]; then
 if [ -n "$SOURCE_FILE" ]; then
  info "Загружаю файл: $SOURCE_VALUE"; SOURCE_JSON=$(api_file "/projects/${PROJECT_UUID}/source-files" "$SOURCE_FILE") || die 'Не удалось загрузить файл'
 else
  info "Загружаю: $URL"; SOURCE_JSON=$(api_json POST "/projects/${PROJECT_UUID}/source-urls" "$(jq -n --arg url "$URL" '{uri:$url}')") || die 'Не удалось загрузить source'
 fi
 SOURCE_UUID=$(jq -r '.sourceUuid // empty' <<<"$SOURCE_JSON"); [ -n "$SOURCE_UUID" ] || die 'Не удалось загрузить source'
 jq --arg n "$PROJECT_NAME" --arg url "$NORM_URL" --arg uuid "$SOURCE_UUID" --arg src_url "$SOURCE_VALUE" --arg date "$(date +%Y-%m-%d)" '.projects[$n].sources[$url]={uuid:$uuid,url:$src_url,title:"",status:"pending",last_used:$date}' "$PROJECT_FILE" > "$PROJECT_FILE.tmp" && mv "$PROJECT_FILE.tmp" "$PROJECT_FILE"
fi
info "Source: $SOURCE_UUID"
info 'Ожидаю обработки…'
for i in $(seq 1 120); do
 SOURCES_JSON=$(all_sources) || die 'Не удалось получить status source'; STATUS=$(jq -r --arg u "$SOURCE_UUID" '.items[] | select(.uuid==$u) | (.preparationStatus // .status) // "processing"' <<<"$SOURCES_JSON" | head -n1)
 jq --arg n "$PROJECT_NAME" --arg u "$SOURCE_UUID" --arg s "$STATUS" '.projects[$n].sources |= with_entries(if .value.uuid == $u then .value.status = $s else . end)' "$PROJECT_FILE" > "$PROJECT_FILE.tmp" && mv "$PROJECT_FILE.tmp" "$PROJECT_FILE"
 case "$STATUS" in ready) info "✓ Готов (попытка $i)"; break;; failed|error) die "Source в ошибке: $STATUS";; *) sleep 5;; esac
 [ "$i" -eq 120 ] && die "Source не готов за ~10 мин (статус: $STATUS). НЕ перезапускайте ingest с тем же URL — источник уже в очереди. Работайте с другими источниками или проверьте статус позже: ingest.sh --check"
done
DOCS_JSON=$(api_json GET "/projects/${PROJECT_UUID}/sources/${SOURCE_UUID}/documents") || die 'Не удалось получить documents'
DOC_COUNT=$(jq '.items | length' <<<"$DOCS_JSON")
if [ "$DOC_COUNT" -eq 0 ]; then
 warn "documents=0: источник пустой — чат и поиск по нему ничего не вернут. Сайт мог не проиндексироваться. Проверьте доступность URL и попробуйте загрузить позже или используйте другой источник."
fi
echo "project_uuid=$PROJECT_UUID"; echo "source_uuid=$SOURCE_UUID"; echo "documents=$DOC_COUNT"; echo "url=$SOURCE_VALUE"
