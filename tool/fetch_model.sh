#!/usr/bin/env bash
# Puts the AnySleep model into assets/models/ so the app works offline and
# does not download it on first start.
#
#   tool/fetch_model.sh                    # download the published ONNX
#   tool/fetch_model.sh path/to/model.onnx # use a local copy
set -euo pipefail
cd "$(dirname "$0")/.."
dest=assets/models/anysleep.onnx
url=$(grep -o "https://github.com[^']*anysleep.onnx" lib/analysis/sleep_staging.dart)
if [[ $# -ge 1 ]]; then
  cp "$1" "$dest"
else
  curl -fL --progress-bar -o "$dest" "$url"
fi
size=$(stat -c %s "$dest" 2>/dev/null || stat -f %z "$dest")
if (( size < 1000000 )); then
  echo "$dest is only $size bytes, not the model." >&2
  rm -f "$dest"
  exit 1
fi
echo "Model ready: $dest ($((size / 1024 / 1024)) MB). Rebuild the app."
