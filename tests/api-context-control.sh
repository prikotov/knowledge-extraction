# API context-control contracts: source processing options (create/update), chat includeComments.
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
DOCS = {"items":[{"uuid":"d1","type":"main","title":"Текст","length":100,"status":"ready"}]}
SSE = 'data: {"choices":[{"delta":{"content":"Ответ из мока"}}]}\n\n'
class H(BaseHTTPRequestHandler):
 def log_message(self,*x): pass
 def reply(self,n,b,ct='application/json'): self.send_response(n); self.send_header('Content-Type',ct); self.end_headers(); self.wfile.write(b.encode())
 def save(self):
  size=int(self.headers.get('Content-Length','0'))
  body=self.rfile.read(size).decode()
  self.server.last=(self.path, body)
  self.server.log=getattr(self.server,'log',[])+[(self.path,body)]
 def do_GET(self):
  if self.path.endswith('/posts'): return self.reply(200,json.dumps([{"path":p,"body":json.loads(b) if b else {}} for p,b in getattr(self.server,'log',[])]))
  if self.path.endswith('/last-post'): path,body=self.server.last; return self.reply(200,json.dumps({"path":path,"body":json.loads(body) if body else {}}))
  if self.path=='/v1/projects': return self.reply(200,'{"items":[],"pagination":{"total":0}}')
  if '/sources?' in self.path: return self.reply(200,'{"items":[{"uuid":"s1","preparationStatus":"ready"}],"pagination":{"total":1}}')
  if self.path.endswith('/documents'): return self.reply(200,json.dumps(DOCS))
  if '/sources/s1' in self.path: return self.reply(200,'{"uuid":"s1","uri":"https://example.com/v","preparationStatus":"ready"}')
  if '/projects/p/sources' in self.path: return self.reply(200,'{"items":[{"uuid":"s1","title":"Текст","preparationStatus":"ready"}],"pagination":{"total":1}}')
  return self.reply(404,'{}')
 def do_POST(self):
  self.save()
  if self.path.endswith('/source-urls'): return self.reply(201,'{"sourceUuid":"s1","status":"pending"}')
  if '/messages' in self.path: return self.reply(200,SSE,'text/event-stream')
  if self.path=='/v1/chats': return self.reply(201,'{"uuid":"c1","includeComments":false}')
  return self.reply(404,'{}')
 def do_PATCH(self):
  self.save()
  if '/sources/s1' in self.path: return self.reply(202,'{"uuid":"s1","preparationStatus":"processing"}')
  if '/chats/c1' in self.path: return self.reply(200,'{"uuid":"c1","includeComments":false}')
  return self.reply(404,'{}')
s=HTTPServer(('127.0.0.1',0),H); print(s.server_port,flush=True); s.serve_forever()
PY
python3 "$TMP/server.py" > "$TMP/port" & PID=$!; until [ -s "$TMP/port" ]; do sleep .05; done
API="http://127.0.0.1:$(cat "$TMP/port")/v1"

# Создание источника с опциями обработки: processing и includeComments в теле запроса.
(cd "$TMP" && TASK_API_URL="$API" ./scripts/ingest.sh --project p \
  --source-url "https://example.com/video" \
  --diarization auto --language ru --include-comments false > "$TMP/create.out")
grep -q 'source_uuid=s1' "$TMP/create.out"
curl -s "$API/last-post" | jq -e '.path == "/v1/projects/p/source-urls"' >/dev/null
curl -s "$API/last-post" | jq -e '.body.uri == "https://example.com/video" and .body.processing.diarization == "auto" and .body.processing.language == "ru" and .body.includeComments == false' >/dev/null

# Валидация значений опций.
if (cd "$TMP" && TASK_API_URL="$API" ./scripts/ingest.sh --project p --source-url "https://example.com/x" --diarization maybe >/dev/null 2>&1); then
  echo 'invalid --diarization unexpectedly accepted' >&2; exit 1
fi

# --update: PATCH тела с новыми параметрами, затем ожидание готовности.
(cd "$TMP" && TASK_API_URL="$API" ./scripts/ingest.sh --project p --update --source s1 \
  --diarization yes --include-comments false > "$TMP/update.out")
grep -q 'source_uuid=s1' "$TMP/update.out"
grep -q 'documents=1' "$TMP/update.out"
curl -s "$API/last-post" | jq -e '.path == "/v1/projects/p/sources/s1"' >/dev/null
curl -s "$API/last-post" | jq -e '.body.processing.diarization == "yes" and .body.includeComments == false' >/dev/null

# Новый чат с --exclude-comments: includeComments=false в теле создания.
(cd "$TMP" && TASK_API_URL="$API" ./scripts/chat.sh --project p --source s1 \
  --exclude-comments --question "тест" > "$TMP/chat.out")
grep -q 'chat_uuid=c1' "$TMP/chat.out"
grep -q 'Ответ из мока' "$TMP/chat.out"
curl -s "$API/posts" | jq -e '[.[] | select(.path=="/v1/chats")][-1].body.includeComments == false' >/dev/null

# Продолжение чата с --exclude-comments: PATCH перед сообщением.
(cd "$TMP" && TASK_API_URL="$API" ./scripts/chat.sh --chat c1 --exclude-comments --question "тест2" > "$TMP/chat2.out" 2>"$TMP/chat2.err")
grep -q 'Комментарии исключены из контекста диалога' "$TMP/chat2.err"
grep -q 'Ответ из мока' "$TMP/chat2.out"
curl -s "$API/posts" | jq -e '[.[] | select(.path=="/v1/chats/c1")][-1].body.includeComments == false' >/dev/null

echo 'api-context-control: ok'
