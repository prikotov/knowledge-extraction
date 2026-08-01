#!/usr/bin/env bash
set -euo pipefail
unset ALL_PROXY HTTPS_PROXY HTTP_PROXY
ROOT=$(cd "$(dirname "$0")/.." && pwd); TMP=$(mktemp -d); trap 'kill "${PID:-}" 2>/dev/null || true; rm -rf "$TMP"' EXIT
cp -R "$ROOT/scripts" "$TMP/scripts"; echo '{"access_token":"test"}' > "$TMP/.task_token.json"; echo '{"uuid":"p","sources":{}}' > "$TMP/.task_project.json"; echo content > "$TMP/video sample.mp4"
cat > "$TMP/server.py" <<'PY'
from http.server import BaseHTTPRequestHandler,HTTPServer
import json
class H(BaseHTTPRequestHandler):
 def log_message(self,*x): pass
 def reply(self,n,b): self.send_response(n); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(b.encode())
 def do_GET(self):
  if self.path=='/v1/projects': return self.reply(200,'{"items":[]}')
  if '/sources?' in self.path: return self.reply(200,'{"items":[{"uuid":"file-1","status":"ready"}],"pagination":{"total":1}}' if getattr(self.server,'uploaded',False) else '{"items":[],"pagination":{"total":0}}')
  return self.reply(200,'{"items":[{}]}')
 def do_POST(self):
  if self.path=='/v1/projects/p/source-files': self.server.uploaded=True; return self.reply(201,'{"sourceUuid":"file-1","status":"pending"}')
  self.reply(404,'{}')
s=HTTPServer(('127.0.0.1',0),H); print(s.server_port,flush=True); s.serve_forever()
PY
python3 "$TMP/server.py" > "$TMP/port" & PID=$!; until [ -s "$TMP/port" ]; do sleep .05; done
TASK_API_URL="http://127.0.0.1:$(cat "$TMP/port")/v1" "$TMP/scripts/ingest.sh" --source-file "$TMP/video sample.mp4" > "$TMP/out"
grep -q 'source_uuid=file-1' "$TMP/out"; jq -e '.sources[] | select(.uuid=="file-1" and .status=="ready")' "$TMP/.task_project.json" >/dev/null
echo 'local-file-upload: ok'
