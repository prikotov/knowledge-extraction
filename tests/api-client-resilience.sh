#!/usr/bin/env bash
# Offline regression tests for pagination/cache merge and Chat HTTP/SSE guards.
set -euo pipefail
unset ALL_PROXY HTTPS_PROXY HTTP_PROXY
ROOT=$(cd "$(dirname "$0")/.." && pwd); TMP=$(mktemp -d); PORT_FILE="$TMP/port"
cleanup() { [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$TMP"; }; trap cleanup EXIT
cp -R "$ROOT/scripts" "$TMP/scripts"; printf '%s\n' '{"access_token":"test-token"}' > "$TMP/.task_token.json"; printf '%s\n' '{"uuid":"","sources":{"old":{"uuid":"u1","status":"pending","note":"keep"}}}' > "$TMP/.task_project.json"
cat > "$TMP/server.py" <<'PY'
from http.server import BaseHTTPRequestHandler,HTTPServer
import json, os
mode=os.environ['MODE']
class H(BaseHTTPRequestHandler):
 def log_message(self,*x): pass
 def reply(self,n,body='',typ='application/json'):
  self.send_response(n); self.send_header('Content-Type',typ); self.end_headers(); self.wfile.write(body.encode())
 def do_GET(self):
  if self.path == '/v1/projects': return self.reply(200,'{"items":[]}')
  if '/sources?' in self.path:
   offset=int(self.path.split('offset=')[1]); items=[{'uuid':'u1','uri':'https://same.example/a','title':'One','status':'ready'},{'uuid':'u2','uri':'https://same.example/a','title':'Two','status':'processing'}]
   return self.reply(200,json.dumps({'items':items[offset:offset+1],'pagination':{'total':2}}))
  return self.reply(200,'{"items":[]}')
 def do_POST(self):
  if mode=='422': return self.reply(422,'{"detail":"Need to top up balance."}')
  if mode=='500': return self.reply(500,'broken','text/plain')
  if mode=='badtype': return self.reply(200,'{"detail":"not sse"}')
  return self.reply(200,'data: {"choices":[{"delta":{"content":"Hello"}}]}\n\n','text/event-stream; charset=utf-8')
s=HTTPServer(('127.0.0.1',0),H); print(s.server_port,flush=True); s.serve_forever()
PY
start() { MODE="$1" python3 "$TMP/server.py" > "$PORT_FILE" & SERVER_PID=$!; for _ in $(seq 1 20); do [ -s "$PORT_FILE" ] && break; sleep .05; done; PORT=$(cat "$PORT_FILE"); }
stop() { kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null || true; unset SERVER_PID; : > "$PORT_FILE"; }
start ok
(cd "$TMP" && TASK_API_URL="http://127.0.0.1:$PORT/v1" ./scripts/ingest.sh --check --project p > "$TMP/check.out")
jq -e '(.sources | length == 2 and ([.[] | .uuid] | sort == ["u1","u2"])) and .sources.old.note == "keep" and .sources.old.status == "ready"' "$TMP/.task_project.json" >/dev/null
grep -q 'импортирован из API' "$TMP/check.out"
stop
if (cd "$TMP" && TASK_API_URL="http://127.0.0.1:1/v1" ./scripts/chat.sh --chat c --question q >"$TMP/out" 2>"$TMP/err"); then echo 'transport unexpectedly succeeded' >&2; exit 1; fi
grep -q 'TasK API request failed.' "$TMP/err"
for mode in 422 500 badtype; do
 start "$mode"
 if (cd "$TMP" && TASK_API_URL="http://127.0.0.1:$PORT/v1" ./scripts/chat.sh --chat c --question q >"$TMP/out" 2>"$TMP/err"); then echo "$mode unexpectedly succeeded" >&2; exit 1; fi
 case "$mode" in 422) grep -q 'HTTP 422: Need to top up balance.' "$TMP/err";; 500) grep -q 'HTTP 500: TasK API returned an unexpected error.' "$TMP/err";; badtype) grep -q 'unexpected response type' "$TMP/err";; esac
 stop
done
start ok
(cd "$TMP" && TASK_API_URL="http://127.0.0.1:$PORT/v1" ./scripts/chat.sh --chat c --question q > "$TMP/out")
grep -q Hello "$TMP/out"
echo 'api-client-resilience: ok'
