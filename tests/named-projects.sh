#!/usr/bin/env bash
# Offline regression test: named research projects stay isolated; legacy layout migrates.
set -euo pipefail
unset ALL_PROXY HTTPS_PROXY HTTP_PROXY
ROOT=$(cd "$(dirname "$0")/.." && pwd); TMP=$(mktemp -d)
cleanup() { [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null || true; rm -rf "$TMP"; }; trap cleanup EXIT
cp -R "$ROOT/scripts" "$TMP/scripts"; echo '{"access_token":"test"}' > "$TMP/.task_token.json"
# Legacy single-project layout must survive the migration untouched.
printf '%s\n' '{"uuid":"legacy","sources":{"https://old.example/":{"uuid":"u0","status":"ready","note":"keep"}}}' > "$TMP/.task_project.json"

cat > "$TMP/server.py" <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
class H(BaseHTTPRequestHandler):
 def log_message(self,*x): pass
 def reply(self,n,b): self.send_response(n); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(b.encode())
 def do_POST(self):
  size=int(self.headers.get('Content-Length','0')); body=json.loads(self.rfile.read(size) or '{}')
  if self.path == '/v1/projects':
   pid={'research-a':'pa','research-b':'pb'}[body['title']]
   return self.reply(200,json.dumps({'uuid':pid}))
  if self.path.endswith('/chunks/search'):
   return self.reply(200,json.dumps({'chunks':[{'chunkNumber':1,'text':'from '+self.path}]}))
  return self.reply(200,'{"sourceUuid":"s1"}')
 def do_GET(self):
  if '/sources?' in self.path:
   return self.reply(200,'{"items":[{"uuid":"s1","uri":"https://a.example/x","title":"A","preparationStatus":"ready"}],"pagination":{"total":1}}')
  if self.path.endswith('/documents'):
   return self.reply(200,'{"items":[{}]}')
  return self.reply(200,'{"items":[]}')
s=HTTPServer(('127.0.0.1',0),H); print(s.server_port,flush=True); s.serve_forever()
PY
python3 "$TMP/server.py" > "$TMP/port" & PID=$!; until [ -s "$TMP/port" ]; do sleep .05; done
API="http://127.0.0.1:$(cat "$TMP/port")/v1"
I() { (cd "$TMP" && TASK_API_URL="$API" ./scripts/ingest.sh "$@"); }
S() { (cd "$TMP" && TASK_API_URL="$API" ./scripts/search.sh "$@"); }

# Each research lands in its own project; the last one becomes active.
I --project-name research-a --source-url "https://a.example/x" > "$TMP/out1"
I --project-name research-b --source-url "https://a.example/x" > "$TMP/out2"
jq -e '.projects["research-a"].uuid == "pa" and .projects["research-b"].uuid == "pb" and .active == "research-b"' "$TMP/.task_project.json" >/dev/null
# Sources are scoped per project even for the same URL.
jq -e '.projects["research-a"].sources | length == 1' "$TMP/.task_project.json" >/dev/null
jq -e '.projects["research-b"].sources | length == 1' "$TMP/.task_project.json" >/dev/null
# Legacy project survives the migration.
jq -e '.projects.default.uuid == "legacy" and .projects.default.sources["https://old.example/"].note == "keep"' "$TMP/.task_project.json" >/dev/null

# Explicit name wins over active; search hits that project's endpoint.
S --project-name research-a --source-url "https://a.example/x" --query q > "$TMP/s1"
grep -q '/projects/pa/chunks/search' "$TMP/s1"
# Without a name the last used project is used (source resolves from its cache).
S --source-url "https://a.example/x" --query q > "$TMP/s2" 2>/dev/null
grep -q '/projects/pb/chunks/search' "$TMP/s2"

echo 'named-projects: ok'
