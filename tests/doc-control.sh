# Source card includes documents (--info) and search can exclude viewer comments (--exclude-comments).
set -euo pipefail
unset ALL_PROXY HTTPS_PROXY HTTP_PROXY
ROOT=$(cd "$(dirname "$0")/.." && pwd); TMP=$(mktemp -d)
cleanup() { kill "${PID:-}" 2>/dev/null || true; rm -rf "$TMP"; }; trap cleanup EXIT
cp -R "$ROOT/scripts" "$TMP/scripts"
echo '{"access_token":"test"}' > "$TMP/.task_token.json"
cat > "$TMP/.knowledge-extraction.json" <<'EOF'
{"projects":{"p":{"uuid":"p","sources":{}}}}
EOF

cat > "$TMP/server.py" <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
DOCS = {"items":[
 {"uuid":"d1","type":"main","title":"Лекция о мозге","length":256000,"status":"ready"},
 {"uuid":"d2","type":"comments","title":"Комментарии к Лекция о мозге","length":122000,"status":"ready"}]}
CHUNKS_FIRST = {"chunks":[
 {"chunkNumber":9,"text":"Транскрипт: мысль автора","documentTitle":"Лекция о мозге"},
 {"chunkNumber":3,"text":"Автор: @x Текст: комментарий зрителя","documentTitle":"Комментарии к Лекция о мозге"}]}
CHUNKS_UNTITLED = {"chunks":[{"chunkNumber":1,"text":"Без заголовка"}]}
class H(BaseHTTPRequestHandler):
 calls = 0
 def log_message(self,*x): pass
 def reply(self,n,b): self.send_response(n); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(b.encode())
 def do_GET(self):
  if self.path.endswith('/documents'): return self.reply(200,json.dumps(DOCS))
  if self.path.endswith('/projects'): return self.reply(200,'{"items":[],"pagination":{"total":0}}')
  if self.path.endswith('/last-post'): return self.reply(200,getattr(self.server,'last_body','{}'))
  if '/sources/s' in self.path: return self.reply(200,'{"uuid":"s","uri":"https://youtu.be/x","preparationStatus":"ready"}')
  return self.reply(404,'{}')
 def do_POST(self):
  size=int(self.headers.get('Content-Length','0')); self.server.last_body=self.rfile.read(size).decode()
  H.calls += 1
  payload = CHUNKS_UNTITLED if H.calls >= 3 else CHUNKS_FIRST
  self.reply(200,json.dumps(payload))
s=HTTPServer(('127.0.0.1',0),H); print(s.server_port,flush=True); s.serve_forever()
PY
python3 "$TMP/server.py" > "$TMP/port" & PID=$!; until [ -s "$TMP/port" ]; do sleep .05; done
API="http://127.0.0.1:$(cat "$TMP/port")/v1"

# --info показывает состав документов источника.
(cd "$TMP" && TASK_API_URL="$API" ./scripts/ingest.sh --project p --info --source s > "$TMP/info")
grep -q '"type": "comments"' "$TMP/info"
grep -q '"title": "Комментарии к Лекция о мозге"' "$TMP/info"
grep -q '"type": "main"' "$TMP/info"

# Обычный поиск возвращает оба чанка и помечает чанк документом.
(cd "$TMP" && TASK_API_URL="$API" ./scripts/search.sh --project p --source s --query q > "$TMP/out1")
grep -q 'Транскрипт: мысль автора' "$TMP/out1"
grep -q 'Комментарии к Лекция о мозге' "$TMP/out1"

# --exclude-comments отсекает чанки комментариев.
(cd "$TMP" && TASK_API_URL="$API" ./scripts/search.sh --project p --source s --query q --exclude-comments > "$TMP/out2" 2>"$TMP/err2")
grep -q 'Транскрипт: мысль автора' "$TMP/out2"
if grep -q 'Комментарии' "$TMP/out2"; then echo 'comment chunk leaked into --exclude-comments output' >&2; exit 1; fi
grep -q 'Исключено чанков из комментариев зрителей: 1' "$TMP/err2"

# Серверный фильтр: в запросе передан documentTypes=["main"].
curl -s "$API/projects/p/chunks/search/last-post" -o "$TMP/last.json"
jq -e '.documentTypes == ["main"]' "$TMP/last.json" >/dev/null

# Null-safe: чанк без documentTitle не ломает вывод.
(cd "$TMP" && TASK_API_URL="$API" ./scripts/search.sh --project p --source s --query q --exclude-comments > "$TMP/out3")
grep -q 'Без заголовка' "$TMP/out3"

echo 'doc-control: ok'
