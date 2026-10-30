#!/bin/sh
set -eu
build_python=python3
previous=
for argument in "$@"; do
    if [ "$previous" = --python ]; then build_python=$argument; break; fi
    case "$argument" in --python=*) build_python=${argument#--python=}; break;; esac
    previous=$argument
done
if ! command -v "$build_python" >/dev/null 2>&1; then
    printf '%s\n' 'Python 3.11+ is required. Install an approved Python, or pass --python /path/to/python3.' >&2
    exit 1
fi
project_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$build_python" "$project_root/scripts/build_installer.py" "$@"
