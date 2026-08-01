#!/usr/bin/env bash
# First-run workspace discovery, URL identity, CLI validation, and search errors.
set -euo pipefail
unset ALL_PROXY HTTPS_PROXY HTTP_PROXY
ROOT=$(cd "$(dirname "$0")/.." && pwd); TMP=$(mktemp -d)
cleanup() { kill "${PID:-}" 2>/dev/null || true; rm -rf "$TMP"; }; trap cleanup EXIT
cp -R "$ROOT/scripts" "$TMP/scripts"; mkdir -p "$TMP/nested/work"
echo '{"access_token":"test"}' > "$TMP/.task_token.json"
echo '{"unrelated_setting":true}' > "$TMP/.task_config.json"

cat > "$TMP/server.py" <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
class H(BaseHTTPRequestHandler):
 def log_message(self,*x): pass
 def reply(self,n,b): self.send_response(n); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(b.encode())
 def do_POST(self):
  size=int(self.headers.get('Content-Length','0')); body=json.loads(self.rfile.read(size) or '{}')
  if body.get('query') == 'fail': return self.reply(422,'{"detail":"Search unavailable."}')
  self.reply(200,'{"chunks":[{"chunkNumber":1,"text":"Found from workspace"}]}')
s=HTTPServer(('127.0.0.1',0),H); print(s.server_port,flush=True); s.serve_forever()
PY
python3 "$TMP/server.py" > "$TMP/port" & PID=$!; until [ -s "$TMP/port" ]; do sleep .05; done
API="http://127.0.0.1:$(cat "$TMP/port")/v1"

# The token is the only first-run marker and is found from a nested caller directory.
(cd "$TMP/nested/work" && TASK_API_URL="$API" "$TMP/scripts/search.sh" --project p --source s --query ok > "$TMP/out")
grep -q 'Found from workspace' "$TMP/out"

if (cd "$TMP/nested/work" && TASK_API_URL="$API" "$TMP/scripts/search.sh" --project p --source s --query fail >"$TMP/out" 2>"$TMP/err"); then
 echo 'search error unexpectedly succeeded' >&2; exit 1
fi
grep -q 'HTTP 422: Search unavailable.' "$TMP/err"
grep -q 'Не удалось выполнить поиск' "$TMP/err"

if (cd "$TMP" && ./scripts/search.sh --query >"$TMP/out" 2>"$TMP/err"); then
 echo 'missing argument unexpectedly succeeded' >&2; exit 1
fi
grep -q 'Для --query нужен текст' "$TMP/err"

# URL path/query and local path case are significant.
PROJECT_FILE=/dev/null source "$TMP/scripts/common.sh"
[ "$(normalize_url 'HTTPS://Example.COM/File?Key=A')" = 'https://example.com/File?Key=A' ]
[ "$(normalize_url 'https://example.com/file?Key=A')" != "$(normalize_url 'https://example.com/File?Key=A')" ]

echo 'workspace-and-search: ok'
