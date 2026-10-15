#!/usr/bin/env bash
# speakers.sh — маппинг меток диаризации (Speaker NN) на имена спикеров.
# Хранится в .knowledge-extraction.json рядом с источником и переиспользуется
# между сессиями: определил маппинг один раз — дальше читай из кеша.
#
# Использование:
#   ./speakers.sh --source <UUID> get
#   ./speakers.sh --source <UUID> set --json '{"Speaker 00": {"name": "Анохин Константин", "role": "гость", "evidence": "Во-первых, я не очень много изучал сознание…"}}'
#   ./speakers.sh --source <UUID> clear
#
# Формат маппинга: ключ — метка из чанков (Speaker NN), значение — объект
# с обязательным name; role и evidence (цитата-основание) — опциональны.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
load_task_environment

SOURCE_UUID=""; PROJECT_NAME_ARG=""; ACTION=""; JSON_INPUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --source)      [ $# -ge 2 ] || die "Для --source нужен UUID"; SOURCE_UUID="$2"; shift 2 ;;
    --project)     [ $# -ge 2 ] || die "Для --project нужно имя проекта (алиас --project-name)"; PROJECT_NAME_ARG="$2"; shift 2 ;;
    --project-name) [ $# -ge 2 ] || die "Для --project-name нужно имя"; PROJECT_NAME_ARG="$2"; shift 2 ;;
    --json)        [ $# -ge 2 ] || die "Для --json нужен JSON маппинга"; JSON_INPUT="$2"; shift 2 ;;
    get|set|clear) ACTION="$1"; shift ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done

[ -n "$ACTION" ] || die "Нужно действие: get, set или clear"
[ -n "$SOURCE_UUID" ] || die "--source обязателен"

PROJECT_NAME=$(resolve_project_name "$PROJECT_NAME_ARG")
[ -f "$PROJECT_FILE" ] || die "Файл кеша не найден: $PROJECT_FILE — сначала загрузите источник"

# Обратный поиск ключа кеша по UUID источника (null-safe: sources может отсутствовать).
CACHE_KEY=$(jq -r --arg n "$PROJECT_NAME" --arg u "$SOURCE_UUID" \
  '[.projects[$n].sources // {} | to_entries[] | select(.value.uuid==$u) | .key][0] // empty' "$PROJECT_FILE")
[ -n "$CACHE_KEY" ] || die "Источник $SOURCE_UUID не найден в кеше проекта «$PROJECT_NAME»"

case "$ACTION" in
  get)
    jq --arg n "$PROJECT_NAME" --arg k "$CACHE_KEY" \
      '.projects[$n].sources[$k].speakers // {}' "$PROJECT_FILE"
    ;;
  set)
    [ -n "$JSON_INPUT" ] || die "Для set нужен --json '<маппинг>' (или передайте JSON через --json \"\$(cat файл)\")"
    # Валидация: ключи Speaker NN, у каждого спикера непустое name.
    jq -e --arg re '^Speaker [0-9]{2}$' '
      (. | keys | all(test($re))) and
      ([.[] | (.name | type == "string" and length > 0)] | all)
    ' >/dev/null 2>&1 <<<"$JSON_INPUT" || die "Невалидный маппинг: ключи должны быть «Speaker NN», у каждого спикера непустое name"
    MAPPING=$(jq -c '. | with_entries(
      .value = {name: .value.name}
        + (if .value.role then {role: .value.role} else {} end)
        + (if .value.evidence then {evidence: .value.evidence} else {} end)
    )' <<<"$JSON_INPUT")
    COUNT=$(jq '[.[]] | length' <<<"$MAPPING")
    jq --arg n "$PROJECT_NAME" --arg k "$CACHE_KEY" --argjson s "$MAPPING" \
      '.projects[$n].sources[$k].speakers = $s' "$PROJECT_FILE" > "$PROJECT_FILE.tmp.$$" \
      && mv "$PROJECT_FILE.tmp.$$" "$PROJECT_FILE"
    info "Маппинг спикеров сохранён ($COUNT сп.): $CACHE_KEY"
    jq '.' <<<"$MAPPING"
    ;;
  clear)
    jq --arg n "$PROJECT_NAME" --arg k "$CACHE_KEY" \
      '.projects[$n].sources[$k] |= (del(.speakers))' "$PROJECT_FILE" > "$PROJECT_FILE.tmp.$$" \
      && mv "$PROJECT_FILE.tmp.$$" "$PROJECT_FILE"
    info "Маппинг спикеров удалён: $CACHE_KEY"
    ;;
esac
