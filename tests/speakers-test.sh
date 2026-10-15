# speakers.sh — маппинг Speaker NN → имена сохраняется в кеш проекта и переиспользуется.
set -euo pipefail
unset ALL_PROXY HTTPS_PROXY HTTP_PROXY
ROOT=$(cd "$(dirname "$0")/.." && pwd); TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }; trap cleanup EXIT
cp -R "$ROOT/scripts" "$TMP/scripts"
echo '{"access_token":"test"}' > "$TMP/.task_token.json"
cat > "$TMP/.knowledge-extraction.json" <<'EOF'
{"projects":{"p":{"uuid":"p","sources":{"text:Тест":{"uuid":"s1","url":"Тест","title":"","status":"ready","last_used":"2026-10-14","kind":"source"}}}}}
EOF
MAPPING='{"Speaker 00": {"name": "Анохин Константин", "role": "гость", "evidence": "Во-первых, я не очень много изучал сознание"}, "Speaker 01": {"name": "Семихатов Алексей", "role": "ведущий", "evidence": "Я Алексей Семихатов, здравствуйте"}}'

# set: сохраняет маппинг в кеш проекта (--project — алиас имени).
(cd "$TMP" && ./scripts/speakers.sh --project p --source s1 set --json "$MAPPING" > "$TMP/out.set")
jq -e '."Speaker 00".name == "Анохин Константин" and ."Speaker 01".role == "ведущий"' "$TMP/out.set" >/dev/null
jq -e '.projects.p.sources["text:Тест"].speakers."Speaker 01".evidence == "Я Алексей Семихатов, здравствуйте"' "$TMP/.knowledge-extraction.json" >/dev/null

# get: читает маппинг из кеша.
(cd "$TMP" && ./scripts/speakers.sh --project p --source s1 get > "$TMP/out.get")
jq -e '."Speaker 00".evidence | contains("сознание")' "$TMP/out.get" >/dev/null

# Валидация: одноразрядная метка отклоняется.
if (cd "$TMP" && ./scripts/speakers.sh --project p --source s1 set --json '{"Speaker 1": {"name": "X"}}' >/dev/null 2>&1); then
  echo 'invalid label unexpectedly accepted' >&2; exit 1
fi

# Валидация: спикер без name отклоняется.
if (cd "$TMP" && ./scripts/speakers.sh --project p --source s1 set --json '{"Speaker 00": {"role": "гость"}}' >/dev/null 2>&1); then
  echo 'speaker without name unexpectedly accepted' >&2; exit 1
fi

# clear: удаляет маппинг.
(cd "$TMP" && ./scripts/speakers.sh --project p --source s1 clear >/dev/null 2>&1)
(cd "$TMP" && ./scripts/speakers.sh --project p --source s1 get) | grep -q '{}'

echo 'speakers: ok'
