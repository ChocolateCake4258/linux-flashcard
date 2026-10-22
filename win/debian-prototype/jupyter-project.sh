#!/bin/bash
# Start a local notebook server using the current project's activated venv.
set -euo pipefail
(( EUID != 0 )) || { printf 'Run as an ordinary Linux user, without sudo.\n' >&2; exit 1; }
if [[ -z ${VIRTUAL_ENV:-} || ! -x $VIRTUAL_ENV/bin/python ]]; then
    printf 'Activate the project venv first: . .venv/bin/activate\n' >&2
    exit 1
fi
export JUPYTER_PREFER_ENV_PATH=1
export BROWSER="${BROWSER:-firefox-esr %s}"
"$VIRTUAL_ENV/bin/python" -m ipykernel install --prefix "$VIRTUAL_ENV" \
    --name pf-python --display-name 'LinuxFlashcard (project)'
exec "$VIRTUAL_ENV/bin/python" -m notebook --ip=127.0.0.1 "$@"
