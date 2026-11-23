#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"
PORT="${PORT:-3000}"
BUILD_DIR="$PROJECT_DIR/dist"
METADATA_DIR="/home/runner/work/_temp/omgithub-web"

run() {
  /usr/bin/time -p "$@"
}

[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT > 0 && PORT < 65536 )) || { echo "Invalid PORT: $PORT" >&2; exit 1; }

if [[ -f package.json ]]; then
  if [[ -f package-lock.json ]]; then
    run npm ci --no-audit --no-fund
  else
    run npm install --no-audit --no-fund
  fi
  run npm run build
  [[ -f "$BUILD_DIR/index.html" ]] || { echo "Build did not create $BUILD_DIR/index.html" >&2; exit 1; }
else
  [[ -f index.html ]] || { echo "Missing project index.html" >&2; exit 1; }
  run mkdir -p "$BUILD_DIR"
  if [[ ! -f "$BUILD_DIR/index.html" || index.html -nt "$BUILD_DIR/index.html" ]]; then
    run cp index.html "$BUILD_DIR/index.html"
  fi
fi

run mkdir -p "$METADATA_DIR"
run python3 -c 'import json,os,sys; json.dump({"project":os.path.realpath(sys.argv[1]),"directory":os.path.realpath(sys.argv[2])},open(sys.argv[3],"w"))' "$PROJECT_DIR" "$BUILD_DIR" "$METADATA_DIR/deployment-output.json"
echo "Serving $BUILD_DIR on 0.0.0.0:$PORT"
run python3 -m http.server "$PORT" --bind 0.0.0.0 --directory "$BUILD_DIR"
