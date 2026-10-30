#!/bin/zsh
set -eu
project_dir="${0:A:h}"
"$project_dir/build.sh"
runtime_dir="${PET_RUNTIME_DIR:-$project_dir/.runtime}"
exec "$project_dir/dist/Agent Companion.app/Contents/MacOS/AgentCompanion" --runtime "$runtime_dir"
