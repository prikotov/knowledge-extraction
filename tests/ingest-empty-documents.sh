#!/usr/bin/env bash
# Offline regression test: empty-document warning and project identity line on ingest.
set -euo pipefail
unset ALL_PROXY HTTPS_PROXY HTTP_PROXY
ROOT=$(cd "$(dirname "$0")/.." && pwd); TMP=$(mktemp -d)
cleanup() { [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null || true; rm -rf "$TMP"; }; trap cleanup EXIT
cp -R "$ROOT/scripts" "$TMP/scripts"; echo '{"access_token":"test"}' > "$TMP/.task_token.json"

cat > "$TMP/server.py" <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
class H(BaseHTTPRequestHandler):
 def log_message(self,*x): pass
 def reply(self,n,b): self.send_response(n); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(b.encode())
 def do_POST(self):
  self.reply(200,'{"uuid":"p1"}') if self.path == '/v1/projects' else self.reply(200,'{"sourceUuid":"s1"}')
 def do_GET(self):
  if '/sources?' in self.path:
   return self.reply(200,'{"items":[{"uuid":"s1","uri":"https://empty.example/a","title":"Empty","preparationStatus":"ready"}],"pagination":{"total":1}}')
  if self.path.endswith('/documents'):
   return self.reply(200,'{"items":[]}')
  return self.reply(200,'{"items":[]}')
s=HTTPServer(('127.0.0.1',0),H); print(s.server_port,flush=True); s.serve_forever()
PY
python3 "$TMP/server.py" > "$TMP/port" & PID=$!; until [ -s "$TMP/port" ]; do sleep .05; done
API="http://127.0.0.1:$(cat "$TMP/port")/v1"

(cd "$TMP" && TASK_API_URL="$API" ./scripts/ingest.sh --source-url "https://empty.example/a" > "$TMP/out" 2> "$TMP/err")

grep -q '^documents=0$' "$TMP/out"
# Project identity is visible so a wrong-workspace mistake is noticeable.
grep -q "Проект: $(basename "$TMP") (p1)" "$TMP/err"
grep -q 'Рабочий каталог' "$TMP/err"
grep -q 'documents=0' "$TMP/err"
grep -q 'чат и поиск по нему ничего не вернут' "$TMP/err"
# Source stays usable (exit 0) — the warning must not break the happy path.
test -f "$TMP/.knowledge-extraction.json"

echo 'ingest-empty-documents: ok'
