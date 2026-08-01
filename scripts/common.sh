#!/usr/bin/env bash

# Shared runtime helpers for the knowledge-extraction scripts.

die() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[INFO]  $*" >&2; }
warn() { echo "[WARN]  $*" >&2; }

resolve_workspace() {
  local start="${KNOWLEDGE_EXTRACTION_WORKSPACE:-$PWD}" dir fallback=""
  dir=$(cd "$start" 2>/dev/null && pwd) || die "Рабочий каталог не найден: $start"
  while [ "$dir" != / ]; do
    if [ -f "$dir/.task_token.json" ]; then
      printf '%s\n' "$dir"
      return
    fi
    if [ -z "$fallback" ] && { [ -f "$dir/.task_config.json" ] || [ -f "$dir/.task_project.json" ]; }; then
      fallback="$dir"
    fi
    dir=$(dirname "$dir")
  done
  if [ -n "$fallback" ]; then printf '%s\n' "$fallback"; return; fi
  cd "$start" 2>/dev/null && pwd
}

load_task_environment() {
  ARTICLE_DIR=$(resolve_workspace)
  PROJECT_FILE="$ARTICLE_DIR/.task_project.json"
  TASK_API_URL="${TASK_API_URL:-https://api.ai-aid.pro/v1}"
  command -v curl >/dev/null || die "Не найден curl"
  command -v jq >/dev/null || die "Не найден jq"

  if [ -f "$ARTICLE_DIR/.task_config.json" ]; then
    jq -e 'type == "object"' "$ARTICLE_DIR/.task_config.json" >/dev/null 2>&1 \
      || die ".task_config.json содержит некорректный JSON"
    local configured_url
    configured_url=$(jq -r '.api_url // empty' "$ARTICLE_DIR/.task_config.json")
    [ -n "$configured_url" ] && TASK_API_URL="$configured_url"
  fi

  [ -f "$ARTICLE_DIR/.task_token.json" ] \
    || die ".task_token.json не найден в $ARTICLE_DIR. Создайте файл с access_token в корне рабочего проекта."
  TASK_API_TOKEN=$(jq -er '.access_token | select(type == "string" and length > 0)' "$ARTICLE_DIR/.task_token.json" 2>/dev/null) \
    || die ".task_token.json должен содержать непустой access_token"
}

# Preserve path and query case. Only scheme and authority are case-insensitive.
normalize_url() {
  local value="$1" scheme authority rest
  if [[ "$value" =~ ^([Hh][Tt][Tt][Pp][Ss]?)://([^/]+)(.*)$ ]]; then
    scheme=$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
    authority=$(printf '%s' "${BASH_REMATCH[2]}" | tr '[:upper:]' '[:lower:]')
    rest="${BASH_REMATCH[3]}"
    printf '%s://%s%s\n' "$scheme" "$authority" "$rest"
  else
    printf '%s\n' "$value"
  fi
}

canonical_file() { realpath -m "$1"; }

cache_source_uuid() {
  local key="$1" original="$2"
  [ -f "$PROJECT_FILE" ] || return 0
  jq -r --arg key "$key" --arg original "$original" '
    .sources[$key].uuid //
    ([.sources[]? | select(.url == $original) | .uuid][0] // empty)
  ' "$PROJECT_FILE"
}

# Successful response body goes to stdout. Safe diagnostics go to stderr.
api_json() {
  local method="$1" path="$2" data="${3:-}" body headers code rc=0 detail
  body=$(mktemp); headers=$(mktemp)
  if [ -n "$data" ]; then
    code=$(curl -sS -o "$body" -D "$headers" -w '%{http_code}' -X "$method" \
      "${TASK_API_URL}${path}" -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $TASK_API_TOKEN" -d "$data" 2>/dev/null) || rc=$?
  else
    code=$(curl -sS -o "$body" -D "$headers" -w '%{http_code}' -X "$method" \
      "${TASK_API_URL}${path}" -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $TASK_API_TOKEN" 2>/dev/null) || rc=$?
  fi
  if [ "$rc" -ne 0 ] || [ "$code" = 000 ]; then
    rm -f "$body" "$headers"; echo 'TasK API request failed.' >&2; return 1
  fi
  if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
    detail=$(jq -r 'if type == "object" and (.detail | type == "string") then .detail else empty end' "$body" 2>/dev/null || true)
    if [ -n "$detail" ]; then echo "HTTP $code: $detail" >&2; else echo "HTTP $code: TasK API returned an unexpected error." >&2; fi
    rm -f "$body" "$headers"; return 1
  fi
  cat "$body"
  rm -f "$body" "$headers"
}
