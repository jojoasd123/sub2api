#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP_USER="${SUB2API_FAST_USER:-ubuntu}"
INJECTOR_DIR="${SUB2API_FAST_INJECTOR_DIR:-/home/ubuntu/apps/sub2api-fast-injector}"
POLICY_DIR="${SUB2API_FAST_POLICY_DIR:-/home/ubuntu/apps/sub2api-fast-policy}"
FASTCTL_PATH="${SUB2API_FASTCTL_PATH:-/usr/local/bin/sub2api-fastctl}"
NGINX_SITE="${SUB2API_NGINX_SITE:-}"
UPSTREAM_NORMAL="${SUB2API_UPSTREAM_NORMAL:-http://127.0.0.1:18081}"
UPSTREAM_FAST="${SUB2API_UPSTREAM_FAST:-http://127.0.0.1:18082}"

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root or with sudo." >&2
    exit 1
  fi
}

resolve_nginx_site() {
  if [ -n "$NGINX_SITE" ]; then
    return
  fi
  if [ -f /etc/nginx/sites-available/sub2api.yuyuan12.top ]; then
    NGINX_SITE=/etc/nginx/sites-available/sub2api.yuyuan12.top
  elif [ -f /etc/nginx/sites-enabled/sub2api.yuyuan12.top ]; then
    NGINX_SITE=/etc/nginx/sites-enabled/sub2api.yuyuan12.top
  elif [ -f /etc/nginx/conf.d/sub2api.yuyuan12.top.conf ]; then
    NGINX_SITE=/etc/nginx/conf.d/sub2api.yuyuan12.top.conf
  fi
}

install_files() {
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"

  install -d -o "$APP_USER" -g "$APP_USER" -m 755 "$INJECTOR_DIR"
  install -d -o "$APP_USER" -g "$APP_USER" -m 700 "$POLICY_DIR"

  if [ -f "$INJECTOR_DIR/server.mjs" ]; then
    cp "$INJECTOR_DIR/server.mjs" "$INJECTOR_DIR/server.mjs.bak-yuyuan-fast-$stamp"
    chown "$APP_USER:$APP_USER" "$INJECTOR_DIR/server.mjs.bak-yuyuan-fast-$stamp"
  fi

  install -o "$APP_USER" -g "$APP_USER" -m 755 "$SCRIPT_DIR/server.mjs" "$INJECTOR_DIR/server.mjs"
  install -m 755 "$SCRIPT_DIR/sub2api-fastctl" "$FASTCTL_PATH"
  install -m 644 "$SCRIPT_DIR/sub2api-fast-injector.service" /etc/systemd/system/sub2api-fast-injector.service
  install -m 644 "$SCRIPT_DIR/sub2api-fast-policy-refresh.service" /etc/systemd/system/sub2api-fast-policy-refresh.service
  install -m 644 "$SCRIPT_DIR/sub2api-fast-policy-refresh.timer" /etc/systemd/system/sub2api-fast-policy-refresh.timer

  chown -R "$APP_USER:$APP_USER" "$POLICY_DIR"
  find "$POLICY_DIR" -type d -exec chmod 700 {} +
  find "$POLICY_DIR" -type f -exec chmod 600 {} +
}

patch_nginx_site() {
  resolve_nginx_site
  if [ -z "$NGINX_SITE" ] || [ ! -f "$NGINX_SITE" ]; then
    echo "nginx site not found; skipping nginx route patch"
    return
  fi

  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  cp "$NGINX_SITE" "$NGINX_SITE.bak-yuyuan-fast-$stamp"

  python3 - "$NGINX_SITE" "$UPSTREAM_NORMAL" "$UPSTREAM_FAST" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
normal = sys.argv[2].rstrip("/")
fast = sys.argv[3].rstrip("/")
text = path.read_text()
routes = ["/responses", "/v1/responses", "/v1/chat/completions", "/v1/completions"]

for route in routes:
    pattern = re.compile(
        r"(location = " + re.escape(route) + r" \{.*?proxy_pass )"
        + re.escape(normal)
        + r"(;.*?\n    \})",
        re.S,
    )
    text, count = pattern.subn(r"\1" + fast + r"\2", text)
    if count == 0:
        already = re.compile(
            r"location = " + re.escape(route) + r" \{.*?proxy_pass "
            + re.escape(fast)
            + r";.*?\n    \}",
            re.S,
        )
        if not already.search(text):
            raise SystemExit(f"expected a location block for {route} using {normal} or {fast}")

path.write_text(text)
PY

  if command -v nginx >/dev/null 2>&1; then
    nginx -t
    systemctl reload nginx
  fi
}

restart_services() {
  systemctl daemon-reload
  systemctl enable --now sub2api-fast-injector.service >/dev/null
  systemctl enable --now sub2api-fast-policy-refresh.timer >/dev/null
  sudo -u "$APP_USER" "$FASTCTL_PATH" refresh
  systemctl restart sub2api-fast-injector.service
}

main() {
  require_root
  install_files
  patch_nginx_site
  restart_services
  sudo -u "$APP_USER" "$FASTCTL_PATH" list
  systemctl is-active sub2api-fast-injector.service
  systemctl is-active sub2api-fast-policy-refresh.timer
}

main "$@"
