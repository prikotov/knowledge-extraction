#!/usr/bin/env bash
# Offline regression test: stdin results are stored as marked compilations, deduped by title.
set -euo pipefail
unset ALL_PROXY HTTPS_PROXY HTTP_PROXY all_proxy https_proxy http_proxy
ROOT=$(cd "$(dirname "$0")/.." && pwd); TMP=$(mktemp -d)
cleanup() { [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null || true; rm -rf "$TMP"; }; trap cleanup EXIT
cp -R "$ROOT/scripts" "$TMP/scripts"; echo '{"access_token":"test"}' > "$TMP/.task_token.json"

cat > "$TMP/server.py" <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
import json, os
OUT=os.environ['STORED_FILE']
class H(BaseHTTPRequestHandler):
 def log_message(self,*x): pass
 def reply(self,n,b): self.send_response(n); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(b.encode())
 def do_POST(self):
  size=int(self.headers.get('Content-Length','0')); body=json.loads(self.rfile.read(size) or '{}')
  if self.path == '/v1/projects': return self.reply(200,'{"uuid":"p1"}')
  if self.path.endswith('/source-contents'):
   with open(OUT,'a') as f: f.write(json.dumps(body,ensure_ascii=False)+'\n')
   return self.reply(200,'{"sourceUuid":"res-1"}')
  return self.reply(200,'{"sourceUuid":"s1"}')
 def do_GET(self):
  if '/sources?' in self.path:
   return self.reply(200,'{"items":[{"uuid":"res-1","uri":"text:Выводы","title":"Выводы","preparationStatus":"ready"}],"pagination":{"total":1}}')
  if self.path.endswith('/documents'): return self.reply(200,'{"items":[{}]}')
  return self.reply(200,'{"items":[]}')
s=HTTPServer(('127.0.0.1',0),H); print(s.server_port,flush=True); s.serve_forever()
PY
STORED_FILE="$TMP/stored.jsonl" python3 "$TMP/server.py" > "$TMP/port" & PID=$!; until [ -s "$TMP/port" ]; do sleep .05; done
API="http://127.0.0.1:$(cat "$TMP/port")/v1"
I() { (cd "$TMP" && TASK_API_URL="$API" ./scripts/ingest.sh "$@"); }

# A research result goes in via stdin as-is; it gets a kind:result label in the cache.
printf 'Вывод: SDD-инструменты различаются workflow, а не форматом.\n' | I --project-name research --source-text --title "Выводы" > "$TMP/out1"
grep -q '^documents=1$' "$TMP/out1"
[ "$(wc -l < "$TMP/stored.jsonl")" = "1" ]
# Content is stored verbatim — no markers glued into the text.
jq -e '(.documentName == "Выводы") and (.content == "Вывод: SDD-инструменты различаются workflow, а не форматом.\n")' "$TMP/stored.jsonl" >/dev/null
# The cache marks it as a result, distinct from primary sources.
jq -e '.projects.research.sources["text:Выводы"].kind == "result" and .projects.research.sources["text:Выводы"].uuid == "res-1"' "$TMP/.task_project.json" >/dev/null

# Same title again is a no-op: the result is already stored.
printf 'Другой текст.\n' | I --project-name research --source-text --title "Выводы" > "$TMP/out2" 2>&1
grep -q 'уже сохранён' "$TMP/out2"
[ "$(wc -l < "$TMP/stored.jsonl")" = "1" ]
# The cache remembers the result under its title key.
jq -e '.projects.research.sources["text:Выводы"].uuid == "res-1"' "$TMP/.task_project.json" >/dev/null

echo 'result-compilation: ok'
