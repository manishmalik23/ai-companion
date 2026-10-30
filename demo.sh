#!/bin/zsh
set -eu
project_dir="${0:A:h}"
exec python3 "$project_dir/bridge.py" demo --runtime "${PET_RUNTIME_DIR:-$project_dir/.runtime}" "$@"
