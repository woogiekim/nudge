#!/usr/bin/env bash
# Installs the core nudge script. Intentionally conservative:
# it does NOT edit your AI tools' config files (to avoid clobbering existing
# settings). Per-tool wiring is done manually using the snippets in examples/.

set -euo pipefail

INSTALL_DIR="${HOME}/.nudge"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Installing nudge to ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
cp "${SRC_DIR}/notify.sh" "${INSTALL_DIR}/notify.sh"
chmod +x "${INSTALL_DIR}/notify.sh"

# Create .env only if it does not already exist (never overwrite your config)
if [[ ! -f "${INSTALL_DIR}/.env" ]]; then
  cp "${SRC_DIR}/.env.example" "${INSTALL_DIR}/.env"
  echo "==> Created ${INSTALL_DIR}/.env  (edit it and set NTFY_TOPIC)"
else
  echo "==> ${INSTALL_DIR}/.env already exists — left untouched"
fi

cat <<EOF

Next steps:
  1. Edit ${INSTALL_DIR}/.env and set a unique NTFY_TOPIC
  2. Subscribe to that same topic in the ntfy app (iOS / Android / desktop / web)
  3. Test it:
       ${INSTALL_DIR}/notify.sh 'Test' 'It works' high
  4. Wire up each AI tool by merging the matching file in examples/
     into that tool's config. These are NOT auto-applied, so your existing
     settings stay intact.
EOF
