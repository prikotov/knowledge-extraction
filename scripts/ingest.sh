#!/usr/bin/env bash
# ingest.sh — загружает URL в TasK, ждёт готовности и кеширует UUID.
# Использование: ./ingest.sh (--source-url <URL> | --source-file <path>) [--project <UUID>]
#               ./ingest.sh --check [--project <UUID>]
#               ./ingest.sh --update --source <UUID> [--diarization auto] [--include-comments false]
# Опции обработки (для url/file/update): --diarization yes|no|auto,
#               --language auto|en|ru|zh, --include-comments true|false
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
load_task_environment

URL=""; SOURCE_FILE=""; SOURCE_TEXT=false; TITLE=""; INFO_SOURCE_UUID=""; LIST_MODE=false; INFO_MODE=false; PROJECT_UUID=""; PROJECT_NAME_ARG=""; PROJECT_DESC_ARG=""; CHECK_ONLY=false
DIARIZATION=""; LANGUAGE=""; INCLUDE_COMMENTS=""; UPDATE_MODE=false
while [ $# -gt 0 ]; do
 case "$1" in
  --source-url) [ $# -ge 2 ] || die "Для --source-url нужен URL"; URL="$2"; shift 2 ;;
  --source-file) [ $# -ge 2 ] || die "Для --source-file нужен путь"; SOURCE_FILE="$2"; shift 2 ;;
  --source-text) SOURCE_TEXT=true; shift ;;
  --title) [ $# -ge 2 ] || die "Для --title нужен текст"; TITLE="$2"; shift 2 ;;
  --project) [ $# -ge 2 ] || die "Для --project нужен UUID"; PROJECT_UUID="$2"; shift 2 ;;
  --project-name) [ $# -ge 2 ] || die "Для --project-name нужно имя"; PROJECT_NAME_ARG="$2"; shift 2 ;;
  --project-description) [ $# -ge 2 ] || die "Для --project-description нужен текст"; PROJECT_DESC_ARG="$2"; shift 2 ;;
  --source) [ $# -ge 2 ] || die "Для --source нужен UUID"; INFO_SOURCE_UUID="$2"; shift 2 ;;
  --list) LIST_MODE=true; shift ;;
  --info) INFO_MODE=true; shift ;;
  --check) CHECK_ONLY=true; shift ;;
  --diarization) [ $# -ge 2 ] || die "Для --diarization нужно значение (yes|no|auto)"; DIARIZATION="$2"; shift 2 ;;
  --language) [ $# -ge 2 ] || die "Для --language нужно значение (auto|en|ru|zh)"; LANGUAGE="$2"; shift 2 ;;
  --include-comments) [ $# -ge 2 ] || die "Для --include-comments нужно значение (true|false)"; INCLUDE_COMMENTS="$2"; shift 2 ;;
  --update) UPDATE_MODE=true; shift ;;
  *) die "Неизвестный аргумент: $1" ;;
 esac
done
if [ -n "$URL" ] && [ -f "$URL" ] && [ -z "$SOURCE_FILE" ]; then SOURCE_FILE="$URL"; URL=""; fi
[ -n "$SOURCE_FILE" ] && [ ! -f "$SOURCE_FILE" ] && die "Файл не найден: $SOURCE_FILE"
[ -n "$URL" ] && [ -n "$SOURCE_FILE" ] && die "Укажите только --source-url или --source-file"
{ [ -n "$URL" ] || [ -n "$SOURCE_FILE" ]; } && $SOURCE_TEXT && die "--source-text не совмещается с --source-url/--source-file"
"$CHECK_ONLY" && $SOURCE_TEXT && die "Для --source-text нужен режим загрузки, а не --check"
if ! "$CHECK_ONLY" && ! $SOURCE_TEXT && ! $LIST_MODE && ! $INFO_MODE && ! $UPDATE_MODE && [ -z "$URL" ] && [ -z "$SOURCE_FILE" ]; then die "Нужен --source-url, --source-file, --list, --info (или --check)"; fi
case "$DIARIZATION" in ""|yes|no|auto) ;; *) die "Недопустимое --diarization: $DIARIZATION (yes|no|auto)" ;; esac
case "$LANGUAGE" in ""|auto|en|ru|zh) ;; *) die "Недопустимое --language: $LANGUAGE (auto|en|ru|zh)" ;; esac
case "$INCLUDE_COMMENTS" in ""|true|false) ;; *) die "Недопустимое --include-comments: $INCLUDE_COMMENTS (true|false)" ;; esac
if $UPDATE_MODE; then
 $SOURCE_TEXT && die "--update не совмещается с --source-text"
 $LIST_MODE && die "--update не совмещается с --list"
 $INFO_MODE && die "--update не совмещается с --info"
 $CHECK_ONLY && die "--update не совмещается с --check"
 [ -n "$URL" ] && [ -n "$SOURCE_FILE" ] && die "Укажите один источник: --source или --source-url"
 [ -z "$URL" ] && [ -z "$SOURCE_FILE" ] && [ -z "$INFO_SOURCE_UUID" ] && die "Для --update нужен --source <UUID> или --source-url"
 [ -z "$DIARIZATION" ] && [ -z "$LANGUAGE" ] && [ -z "$INCLUDE_COMMENTS" ] && die 'Для --update укажите хотя бы одну опцию: --diarization, --language или --include-comments'
fi
{ $LIST_MODE && $INFO_MODE; } && die "Выберите --list или --info"
[ -n "$URL" ] && [ -n "$INFO_SOURCE_UUID" ] && die "Укажите один источник: --source или --source-url"
$LIST_MODE && $SOURCE_TEXT && die "--list не совмещается с --source-text"
$SOURCE_TEXT && [ -t 0 ] && die '--source-text читает контент из stdin: echo "текст" | ingest.sh --source-text --title "Название"'

api_file() {
 local path="$1" file="$2"; shift 2
 local body headers code rc detail
 body=$(mktemp); headers=$(mktemp)
 code=$(curl -sS --connect-timeout 10 --max-time 600 -o "$body" -D "$headers" -w '%{http_code}' -X POST "${TASK_API_URL}${path}" -H "Authorization: Bearer $TASK_API_TOKEN" -F "file=@${file}" "$@" 2>/dev/null) || rc=$?
 if [ "${rc:-0}" -ne 0 ] || [ "$code" = 000 ]; then rm -f "$body" "$headers"; echo 'TasK API request failed.' >&2; return 1; fi
 if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
  detail=$(jq -r 'if type == "object" and (.detail | type == "string") then .detail else empty end' "$body" 2>/dev/null || true)
  if [ -n "$detail" ]; then echo "HTTP $code: $detail" >&2; else echo "HTTP $code: TasK API returned an unexpected error." >&2; fi
  rm -f "$body" "$headers"; return 1
 fi
 cat "$body"; rm -f "$body" "$headers"
}

# Опции обработки: JSON-фрагменты тела запроса (только заданные поля) —
# processing.diarization / processing.language / includeComments.
processing_body() {
 jq -n --arg d "$DIARIZATION" --arg l "$LANGUAGE" \
  '{diarization: (if $d == "" then null else $d end), language: (if $l == "" then null else $l end)}
   | with_entries(select(.value != null))
   | if length == 0 then {} else {processing: .} end'
}
include_comments_body() {
 if [ -n "$INCLUDE_COMMENTS" ]; then jq -n --argjson v "$INCLUDE_COMMENTS" '{includeComments: $v}'; else echo '{}'; fi
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
  && die "Для --check нужен существующий .knowledge-extraction.json или --project"
PROJECT_NAME=$(resolve_project_name "$PROJECT_NAME_ARG")
api_json GET '/projects' >/dev/null || die 'TasK API недоступен'
[ -f "$PROJECT_FILE" ] || echo '{"active":"","projects":{}}' > "$PROJECT_FILE"
CACHED_PROJECT_UUID=$(jq -r --arg n "$PROJECT_NAME" '.projects[$n].uuid // empty' "$PROJECT_FILE")
if [ -n "$PROJECT_UUID" ] && [ -n "$CACHED_PROJECT_UUID" ] && [ "$PROJECT_UUID" != "$CACHED_PROJECT_UUID" ]; then
 die "--project не совпадает с UUID проекта «$PROJECT_NAME» в .knowledge-extraction.json"
fi
[ -z "$PROJECT_UUID" ] && PROJECT_UUID="$CACHED_PROJECT_UUID"
"$CHECK_ONLY" && [ -z "$PROJECT_UUID" ] && die "Для --check нужен существующий .knowledge-extraction.json или --project"
if [ "$PROJECT_NAME" = "default" ]; then PROJECT_TITLE=$(basename "$ARTICLE_DIR"); else PROJECT_TITLE="$PROJECT_NAME"; fi
if [ -n "$PROJECT_UUID" ]; then
 jq --arg n "$PROJECT_NAME" --arg uuid "$PROJECT_UUID" --arg t "$PROJECT_TITLE" --arg d "$PROJECT_DESC_ARG" '(.projects[$n].sources //= {}) | .projects[$n].uuid=$uuid | .projects[$n].title=$t | (if $d != "" then .projects[$n].description=$d else . end) | .active=$n' "$PROJECT_FILE" > "$PROJECT_FILE.tmp.$$" && mv "$PROJECT_FILE.tmp.$$" "$PROJECT_FILE"
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
 jq --arg n "$PROJECT_NAME" --arg uuid "$PROJECT_UUID" --arg t "$PROJECT_TITLE" --arg d "$PROJECT_DESC_ARG" '(.projects[$n].sources //= {}) | .projects[$n].uuid=$uuid | .projects[$n].title=$t | (if $d != "" then .projects[$n].description=$d else . end) | .active=$n' "$PROJECT_FILE" > "$PROJECT_FILE.tmp.$$" && mv "$PROJECT_FILE.tmp.$$" "$PROJECT_FILE"
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
  uri=$(printf %s "$encoded" | base64 -d | jq -r '.uri // .url // ""'); title=$(printf %s "$encoded" | base64 -d | jq -r '.title // ""'); status=$(printf %s "$encoded" | base64 -d | jq -r '.preparationStatus // "unknown"')
  existing=$(jq -r --arg n "$PROJECT_NAME" --arg u "$uuid" '(.projects[$n].sources // {}) | to_entries[]? | select(.value.uuid==$u) | .key' "$PROJECT_FILE" | head -n1)
  if [ -n "$existing" ]; then
   old_status=$(jq -r --arg n "$PROJECT_NAME" --arg k "$existing" '.projects[$n].sources[$k].status // "unknown"' "$PROJECT_FILE")
   jq --arg n "$PROJECT_NAME" --arg k "$existing" --arg s "$status" '.projects[$n].sources[$k].status=$s' "$PROJECT_FILE" > "$PROJECT_FILE.tmp.$$" && mv "$PROJECT_FILE.tmp.$$" "$PROJECT_FILE"
   if [ "$old_status" != "$status" ]; then echo "$existing → $status (был: $old_status) ✦"; updated=$((updated + 1)); fi
  else
   key_base=$(normalize_url "$uri"); key="$key_base"
   [ -n "$key" ] || key="$uuid"
   if jq -e --arg n "$PROJECT_NAME" --arg k "$key" '.projects[$n].sources[$k] != null' "$PROJECT_FILE" >/dev/null; then key="${key_base}#${uuid}"; fi
   jq --arg n "$PROJECT_NAME" --arg k "$key" --arg u "$uuid" --arg url "$uri" --arg title "$title" --arg status "$status" --arg date "$(date +%Y-%m-%d)" \
    '.projects[$n].sources[$k]={uuid:$u,url:$url,title:$title,status:$status,last_used:$date,kind:"source"}' "$PROJECT_FILE" > "$PROJECT_FILE.tmp.$$" && mv "$PROJECT_FILE.tmp.$$" "$PROJECT_FILE"
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

# Метаданные всех источников проекта (статус, длительность, заголовок).
if $LIST_MODE; then
 SOURCES_JSON=$(all_sources) || die 'Не удалось получить sources'
 jq -r '.items[] | ((.duration // 0) | floor) as $d | (.size // .diskSize // 0) as $sz | (if $sz >= 1048576 then "\($sz / 1048576 * 10 | round / 10) МБ" elif $sz >= 1024 then "\($sz / 1024 | round) КБ" elif $sz > 0 then "\($sz) Б" else "-" end) as $szs | "\(.preparationStatus)\t\(if $d > 0 then "\($d / 60 | floor) мин" else "-" end)\t\($szs)\t\(.title // "")\t\(.uri)"' <<<"$SOURCES_JSON"
 exit 0
fi

# Полная карточка источника: описание с таймкодами, длительность, метаданные.
if $INFO_MODE; then
 [ -z "$URL" ] && [ -z "$INFO_SOURCE_UUID" ] && die 'Для --info нужен --source-url или --source'
 [ -z "$INFO_SOURCE_UUID" ] && INFO_SOURCE_UUID=$(cache_source_uuid "$(normalize_url "$URL")" "$URL")
 [ -n "$INFO_SOURCE_UUID" ] || die 'Источник не найден в кеше — сначала загрузите его'
 SOURCE_INFO=$(api_json GET "/projects/${PROJECT_UUID}/sources/${INFO_SOURCE_UUID}") || die 'Не удалось получить источник'
 DOCS_INFO=$(api_json GET "/projects/${PROJECT_UUID}/sources/${INFO_SOURCE_UUID}/documents" 2>/dev/null || echo '{"items":[]}')
 CACHE_KEY=$(jq -r --arg n "$PROJECT_NAME" --arg u "$INFO_SOURCE_UUID" \
   '[.projects[$n].sources | to_entries[]? | select(.value.uuid==$u) | .key][0] // empty' "$PROJECT_FILE")
 SPEAKERS_INFO=$(jq --arg n "$PROJECT_NAME" --arg k "$CACHE_KEY" \
   'if $k == "" then {} else (.projects[$n].sources[$k].speakers // {}) end' "$PROJECT_FILE")
 jq -n --argjson src "$SOURCE_INFO" --argjson docs "$(jq '[.items[]? | {type: (.type // "?"), title: (.title // ""), length: (.length // 0), status: (.status // "?")}]' <<<"$DOCS_INFO")" --argjson sp "$SPEAKERS_INFO" \
   '($src | {uri, title, type, status: .preparationStatus, duration, size, diskSize, channel, description}) + {documents: $docs} + {speakers: $sp}'
 exit 0
fi

# Обновление параметров обработки существующего источника (диаризация, язык, комментарии).
# PATCH /projects/{p}/sources/{uuid} — 202, обработка идёт заново (или подхватывается
# готовый вариант того же профиля); ждём готовности как при загрузке.
if $UPDATE_MODE; then
 if [ -z "$INFO_SOURCE_UUID" ]; then
  INFO_SOURCE_UUID=$(cache_source_uuid "$(normalize_url "$URL")" "$URL")
 fi
 [ -n "$INFO_SOURCE_UUID" ] || die 'Источник не найден в кеше — укажите --source <UUID> или --source-url'
 BODY=$(jq -sc 'add // {}' <(processing_body) <(include_comments_body))
 info "Обновляю параметры обработки: $INFO_SOURCE_UUID"
 api_json PATCH "/projects/${PROJECT_UUID}/sources/${INFO_SOURCE_UUID}" "$BODY" >/dev/null || die 'Не удалось обновить источник'
 sleep 20  # workflow перезапускается асинхронно — даём статусу уйти с прошлого значения
 info 'Ожидаю обработки…'
 for i in $(seq 1 120); do
  SOURCES_JSON=$(all_sources) || die 'Не удалось получить status source'; STATUS=$(jq -r --arg u "$INFO_SOURCE_UUID" '.items[] | select(.uuid==$u) | .preparationStatus // "processing"' <<<"$SOURCES_JSON" | head -n1)
  jq --arg n "$PROJECT_NAME" --arg u "$INFO_SOURCE_UUID" --arg s "$STATUS" '.projects[$n].sources |= with_entries(if .value.uuid == $u then .value.status = $s else . end)' "$PROJECT_FILE" > "$PROJECT_FILE.tmp.$$" && mv "$PROJECT_FILE.tmp.$$" "$PROJECT_FILE"
  case "$STATUS" in ready) info "✓ Готов (попытка $i)"; break;; failed|error) die "Source в ошибке: $STATUS";; *) sleep 5;; esac
  [ "$i" -eq 120 ] && die "Source не готов за ~10 мин (статус: $STATUS). Проверьте статус позже: ingest.sh --check"
 done
 DOCS_JSON=$(api_json GET "/projects/${PROJECT_UUID}/sources/${INFO_SOURCE_UUID}/documents") || die 'Не удалось получить documents'
 DOC_COUNT=$(jq '.items | length' <<<"$DOCS_JSON")
 jq -r '.items[]? | "документ: \(.type // "?") [\(.length // 0) знаков] \(.title // "")"' <<<"$DOCS_JSON" | while IFS= read -r l; do info "$l"; done
 URL_OUT=$(jq -r --arg n "$PROJECT_NAME" --arg u "$INFO_SOURCE_UUID" '[.projects[$n].sources | to_entries[] | select(.value.uuid==$u) | .key][0] // $u' "$PROJECT_FILE")
 echo "project_uuid=$PROJECT_UUID"; echo "source_uuid=$INFO_SOURCE_UUID"; echo "documents=$DOC_COUNT"; echo "url=$URL_OUT"
 exit 0
fi

# Результат ресёрча: текст из stdin — это компиляция, а не первоисточник.
# Сохраняется как есть; от первоисточников отличается меткой kind: result в
# .knowledge-extraction.json (см. также пометку в выводе search.sh).
if $SOURCE_TEXT; then
 TEXT_FILE=$(mktemp)
 cat > "$TEXT_FILE"
 [ -s "$TEXT_FILE" ] || { rm -f "$TEXT_FILE"; die 'stdin пуст — нечего сохранять'; }
 TITLE="${TITLE:-Результат ресёрча $(date +%Y-%m-%d)}"; TITLE="${TITLE:0:255}"
 NORM_URL="text:$TITLE"; SOURCE_VALUE="$TITLE"
 SOURCE_UUID=$(cache_source_uuid "$NORM_URL" "$SOURCE_VALUE")
 if [ -n "$SOURCE_UUID" ]; then
  info "Результат с названием «$TITLE» уже сохранён (source $SOURCE_UUID) — пропускаю. Новая версия — под другим названием."
 else
  info "Сохраняю результат: $TITLE"
  PAYLOAD=$(jq -n --rawfile c "$TEXT_FILE" --arg n "$TITLE" '{content:$c, documentName:$n}')
  SOURCE_JSON=$(api_json POST "/projects/${PROJECT_UUID}/source-contents" "$PAYLOAD") || { rm -f "$TEXT_FILE"; die 'Не удалось сохранить результат'; }
  SOURCE_UUID=$(jq -r '.sourceUuid // empty' <<<"$SOURCE_JSON"); [ -n "$SOURCE_UUID" ] || { rm -f "$TEXT_FILE"; die 'Не удалось сохранить результат'; }
  jq --arg n "$PROJECT_NAME" --arg key "$NORM_URL" --arg uuid "$SOURCE_UUID" --arg url "$SOURCE_VALUE" --arg date "$(date +%Y-%m-%d)" \
   '.projects[$n].sources[$key]={uuid:$uuid,url:$url,title:"",status:"pending",last_used:$date,kind:"result"}' "$PROJECT_FILE" > "$PROJECT_FILE.tmp.$$" && mv "$PROJECT_FILE.tmp.$$" "$PROJECT_FILE"
  rm -f "$TEXT_FILE"
 fi
 rm -f "$TEXT_FILE"
else
if [ -n "$SOURCE_FILE" ]; then SOURCE_VALUE=$(canonical_file "$SOURCE_FILE"); NORM_URL="$SOURCE_VALUE"; else SOURCE_VALUE="$URL"; NORM_URL=$(normalize_url "$URL"); fi
SOURCE_UUID=$(cache_source_uuid "$NORM_URL" "$SOURCE_VALUE")
SOURCES_JSON=$(all_sources) || die 'Не удалось получить sources'
MERGED_IMPORTED=0; MERGED_UPDATED=0; merge_sources "$SOURCES_JSON" >/dev/null
SOURCE_UUID=$(cache_source_uuid "$NORM_URL" "$SOURCE_VALUE")
if [ -z "$SOURCE_UUID" ] && [ -z "$SOURCE_FILE" ]; then SOURCE_UUID=$(jq -r --arg url "$URL" '.items[] | select((.uri // .url // "") == $url) | .uuid' <<<"$SOURCES_JSON" | head -n1); fi
if [ -z "$SOURCE_UUID" ]; then
 if [ -n "$SOURCE_FILE" ]; then
  info "Загружаю файл: $SOURCE_VALUE"
  EXTRA_FILE=()
  [ -n "$INCLUDE_COMMENTS" ] && EXTRA_FILE+=(-F "includeComments=$INCLUDE_COMMENTS")
  # Multipart: processing — вложенные поля (processing[diarization]=…), а не JSON-строка.
  [ -n "$DIARIZATION" ] && EXTRA_FILE+=(-F "processing[diarization]=$DIARIZATION")
  [ -n "$LANGUAGE" ] && EXTRA_FILE+=(-F "processing[language]=$LANGUAGE")
  SOURCE_JSON=$(api_file "/projects/${PROJECT_UUID}/source-files" "$SOURCE_FILE" ${EXTRA_FILE[@]+"${EXTRA_FILE[@]}"}) || die 'Не удалось загрузить файл'
 else
  info "Загружаю: $URL"
  EXTRA=$(jq -sc 'add // {}' <(processing_body) <(include_comments_body))
  SOURCE_JSON=$(api_json POST "/projects/${PROJECT_UUID}/source-urls" \
    "$(jq -cn --arg url "$URL" --argjson extra "$EXTRA" '{uri:$url} + $extra')") || die 'Не удалось загрузить source'
 fi
 SOURCE_UUID=$(jq -r '.sourceUuid // empty' <<<"$SOURCE_JSON"); [ -n "$SOURCE_UUID" ] || die 'Не удалось загрузить source'
 jq --arg n "$PROJECT_NAME" --arg url "$NORM_URL" --arg uuid "$SOURCE_UUID" --arg src_url "$SOURCE_VALUE" --arg date "$(date +%Y-%m-%d)" '.projects[$n].sources[$url]={uuid:$uuid,url:$src_url,title:"",status:"pending",last_used:$date,kind:"source"}' "$PROJECT_FILE" > "$PROJECT_FILE.tmp.$$" && mv "$PROJECT_FILE.tmp.$$" "$PROJECT_FILE"
fi
fi
info "Source: $SOURCE_UUID"
info 'Ожидаю обработки…'
for i in $(seq 1 120); do
 SOURCES_JSON=$(all_sources) || die 'Не удалось получить status source'; STATUS=$(jq -r --arg u "$SOURCE_UUID" '.items[] | select(.uuid==$u) | .preparationStatus // "processing"' <<<"$SOURCES_JSON" | head -n1)
 jq --arg n "$PROJECT_NAME" --arg u "$SOURCE_UUID" --arg s "$STATUS" '.projects[$n].sources |= with_entries(if .value.uuid == $u then .value.status = $s else . end)' "$PROJECT_FILE" > "$PROJECT_FILE.tmp.$$" && mv "$PROJECT_FILE.tmp.$$" "$PROJECT_FILE"
 case "$STATUS" in ready) info "✓ Готов (попытка $i)"; break;; failed|error) die "Source в ошибке: $STATUS";; *) sleep 5;; esac
 [ "$i" -eq 120 ] && die "Source не готов за ~10 мин (статус: $STATUS). НЕ перезапускайте ingest с тем же URL — источник уже в очереди. Работайте с другими источниками или проверьте статус позже: ingest.sh --check"
done
DOCS_JSON=$(api_json GET "/projects/${PROJECT_UUID}/sources/${SOURCE_UUID}/documents") || die 'Не удалось получить documents'
DOC_COUNT=$(jq '.items | length' <<<"$DOCS_JSON")
# Состав источника в stderr: транскрипт и комментарии попадают в чат наравне.
jq -r '.items[]? | "документ: \(.type // "?") [\(.length // 0) знаков] \(.title // "")"' <<<"$DOCS_JSON" | while IFS= read -r l; do info "$l"; done
if [ "$DOC_COUNT" -eq 0 ]; then
 warn "documents=0: источник пустой — чат и поиск по нему ничего не вернут. Сайт мог не проиндексироваться. Проверьте доступность URL и попробуйте загрузить позже или используйте другой источник."
fi
echo "project_uuid=$PROJECT_UUID"; echo "source_uuid=$SOURCE_UUID"; echo "documents=$DOC_COUNT"; echo "url=$SOURCE_VALUE"
