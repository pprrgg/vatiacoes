#!/usr/bin/env bash
#
# Alterna la URL base de la API entre el servidor local de pruebas y el
# de producción, tanto en public/docs/**/*.html como en el login/registro
# de public/js/auth-guard.js.
#
# Uso:
#   scripts/set-docs-url.sh prod   # 127.0.0.1:8888 -> doctec.duckdns.org
#   scripts/set-docs-url.sh local  # doctec.duckdns.org -> 127.0.0.1:8888

set -euo pipefail

LOCAL_URL="http://127.0.0.1:8888/"
PROD_URL="https://doctec.duckdns.org/fast/"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCS_DIR="$ROOT_DIR/public/docs"
AUTH_GUARD_FILE="$ROOT_DIR/public/js/auth-guard.js"

MODE="${1:-}"
case "$MODE" in
  prod)
    FROM="$LOCAL_URL"
    TO="$PROD_URL"
    ;;
  local)
    FROM="$PROD_URL"
    TO="$LOCAL_URL"
    ;;
  *)
    echo "Uso: $0 {prod|local}" >&2
    exit 1
    ;;
esac

DOCS_FILES=$(grep -rlF --include="*.html" "$FROM" "$DOCS_DIR" || true)

AUTH_GUARD_MATCH=""
if [ -f "$AUTH_GUARD_FILE" ] && grep -qF "$FROM" "$AUTH_GUARD_FILE"; then
  AUTH_GUARD_MATCH="$AUTH_GUARD_FILE"
fi

FILES=$(printf '%s\n%s\n' "$DOCS_FILES" "$AUTH_GUARD_MATCH" | sed '/^$/d')

if [ -z "$FILES" ]; then
  echo "set-docs-url: sin referencias a $FROM, no hay nada que cambiar."
  exit 0
fi

echo "$FILES" | while IFS= read -r file; do
  sed -i "s|$FROM|$TO|g" "$file"
done

COUNT=$(echo "$FILES" | wc -l)
echo "set-docs-url: $COUNT archivo(s) actualizados a modo '$MODE' ($TO)."
