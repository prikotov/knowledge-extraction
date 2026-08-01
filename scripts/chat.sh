#!/usr/bin/env bash
# chat.sh — диалог с документом через TasK Chat API.
# Один вопрос за вызов. Чтобы продолжить — передай --chat <UUID>.
#
# Использование:
#   ./chat.sh --source-url <URL>                          # начать диалог (1-й вопрос)
#   ./chat.sh --source-url <URL> --question "..."         # начать со своего вопроса
#   ./chat.sh --source-url <URL> --title "Моя тема"       # задать имя чата
#   ./chat.sh --chat <UUID> --question "..."       # продолжить диалог

set -euo pipefail

# ─── config ────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
load_task_environment

# ─── args ──────────────────────────────────────────

URL=""
SOURCE_UUIDS=()
PROJECT_UUID=""
QUESTION=""
CHAT_UUID=""
TITLE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --source-url) [ $# -ge 2 ] || die "Для --source-url нужен URL"; URL="$2"; shift 2 ;;
    --source)     [ $# -ge 2 ] || die "Для --source нужен UUID"; SOURCE_UUIDS+=("$2"); shift 2 ;;
    --project)    [ $# -ge 2 ] || die "Для --project нужен UUID"; PROJECT_UUID="$2"; shift 2 ;;
    --question)   [ $# -ge 2 ] || die "Для --question нужен текст"; QUESTION="$2"; shift 2 ;;
    --chat)       [ $# -ge 2 ] || die "Для --chat нужен UUID"; CHAT_UUID="$2"; shift 2 ;;
    --title)      [ $# -ge 2 ] || die "Для --title нужен текст"; TITLE="$2"; shift 2 ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done

# ─── resolve source ────────────────────────────────

[ -z "$PROJECT_UUID" ] && [ -f "$PROJECT_FILE" ] && PROJECT_UUID=$(jq -r '.uuid // empty' "$PROJECT_FILE")

# --source-url → resolve to UUID from cache
if [ -n "$URL" ]; then
  RESOLVED=$(cache_source_uuid "$(normalize_url "$URL")" "$URL")
  if [ -n "$RESOLVED" ]; then
    SOURCE_UUIDS+=("$RESOLVED")
  elif [ -z "$CHAT_UUID" ]; then
    warn "URL не найден в кеше — сначала запустите ingest.sh. Пока чат будет использовать все source'ы проекта."
  fi
fi

# Убрать дубликаты
if [ ${#SOURCE_UUIDS[@]} -gt 0 ]; then
  UNIQUE_SOURCE_UUIDS=()
  while IFS= read -r uuid; do UNIQUE_SOURCE_UUIDS+=("$uuid"); done < <(printf '%s\n' "${SOURCE_UUIDS[@]}" | sort -u)
  SOURCE_UUIDS=("${UNIQUE_SOURCE_UUIDS[@]}")
fi

# ─── API wrapper ───────────────────────────────────

# The messages endpoint must be a successful SSE response; never parse error text as SSE.
api_sse() {
  local path="$1" data="$2" body headers code rc content_type
  body=$(mktemp); headers=$(mktemp)
  code=$(curl -sS --no-buffer --max-time 120 -o "$body" -D "$headers" -w '%{http_code}' \
    -H "Authorization: Bearer $TASK_API_TOKEN" -H 'Content-Type: application/json' \
    -d "$data" "${TASK_API_URL}${path}" 2>/dev/null) || rc=$?
  if [ "${rc:-0}" -ne 0 ] || [ "$code" = "000" ]; then rm -f "$body" "$headers"; echo 'TasK API request failed.' >&2; return 1; fi
  if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
    local detail; detail=$(jq -r 'if type == "object" and (.detail | type == "string") then .detail else empty end' "$body" 2>/dev/null || true)
    if [ -n "$detail" ]; then echo "HTTP $code: $detail" >&2; else echo "HTTP $code: TasK API returned an unexpected error." >&2; fi
    rm -f "$body" "$headers"; return 1
  fi
  content_type=$(tr -d '\r' < "$headers" | awk 'BEGIN{IGNORECASE=1} /^Content-Type:/{sub(/^[^:]*:[[:space:]]*/, ""); print; exit}')
  if [[ "$content_type" != text/event-stream* ]]; then
    rm -f "$body" "$headers"; echo "HTTP $code: TasK API returned an unexpected response type." >&2; return 1
  fi
  cat "$body"; rm -f "$body" "$headers"
}
parse_sse() {
  grep '^data: ' | sed 's/^data: //' | jq -r '
    select(.choices != null) | .choices[0].delta.content // empty
  ' 2>/dev/null | tr -d '\n' | sed 's/\r//g'
}

# ─── Новый диалог или продолжение ──────────────────

if [ -z "$CHAT_UUID" ]; then
  [ -z "$PROJECT_UUID" ] && die "Не указан project (--project или .task_project.json)"

  # Метаданные sources — нужны для title и вопроса по умолчанию
  SRC_META=$(api_json GET "/projects/${PROJECT_UUID}/sources") || die "Не удалось получить sources"

  # Первый вопрос по умолчанию
  if [ -z "$QUESTION" ]; then
    SRC_TITLE=""
    # Берём title первого source'а, если он указан
    if [ ${#SOURCE_UUIDS[@]} -gt 0 ]; then
      SRC_TITLE=$(echo "$SRC_META" | jq -r --arg uuid "${SOURCE_UUIDS[0]}" \
        '.items[] | select(.uuid==$uuid) | .title // ""' 2>/dev/null)
    fi
    if [ -n "$SRC_TITLE" ]; then
      QUESTION="О чём этот материал? Название: «${SRC_TITLE}»."
    else
      QUESTION="О чём этот материал?"
    fi
  fi

  SRC_COUNT=${#SOURCE_UUIDS[@]}
  [ "$SRC_COUNT" -gt 0 ] && SRC_INFO="источников: $SRC_COUNT" || SRC_INFO="все источники проекта"
  info "Новый диалог ($SRC_INFO)"

  # Собрать JSON для создания чата
  # Имя чата: --title → заголовок первого source → «Диалог с материалом»
  if [ -z "$TITLE" ]; then
    if [ ${#SOURCE_UUIDS[@]} -gt 0 ]; then
      FIRST_TITLE=$(echo "$SRC_META" | jq -r --arg uuid "${SOURCE_UUIDS[0]}" \
        '.items[] | select(.uuid==$uuid) | .title // ""' 2>/dev/null)
      [ -n "$FIRST_TITLE" ] && TITLE="$FIRST_TITLE"
    fi
  fi
  [ -z "$TITLE" ] && TITLE="Диалог с материалом"

  CHAT_DATA=$(jq -n \
    --arg project "$PROJECT_UUID" \
    --arg title "$TITLE" \
    '{projectUuid: $project, title: $title}')
  if [ ${#SOURCE_UUIDS[@]} -gt 0 ]; then
    SRC_JSON=$(printf '%s\n' "${SOURCE_UUIDS[@]}" | jq -R . | jq -s '{sourcesUuids: .}')
    CHAT_DATA=$(echo "$CHAT_DATA" | jq --argjson srcs "$SRC_JSON" '. + $srcs')
  fi

  CHAT_JSON=$(api_json POST "/chats" "$CHAT_DATA") || die "Не удалось создать чат"
  CHAT_UUID=$(echo "$CHAT_JSON" | jq -r '.uuid // empty')
  [ -z "$CHAT_UUID" ] && die "Не удалось создать чат"
  echo "chat_uuid=$CHAT_UUID"
else
  [ -z "$QUESTION" ] && die "Для продолжения диалога нужен --question"
  info "Продолжаю диалог $CHAT_UUID"
fi

# ─── Задать вопрос ─────────────────────────────────

info "Вопрос: ${QUESTION:0:100}…"

SSE_BODY=$(mktemp)
api_sse "/chats/${CHAT_UUID}/messages" "$(jq -n --arg msg "$QUESTION" '{message: $msg}')" > "$SSE_BODY" || { rm -f "$SSE_BODY"; exit 1; }
ANSWER=$(parse_sse < "$SSE_BODY")
rm -f "$SSE_BODY"

echo ""
echo "### ${QUESTION}"
echo ""
echo "${ANSWER}"
