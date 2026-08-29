#!/usr/bin/env bash
# Release APK with dart-defines from gitignored config.json
# (GEMMA_MODEL_URL, HUGGINGFACE_TOKEN, …). Plain `flutter build apk`
# bakes the Hugging Face fallback instead of the R2 mirror.
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
cd "$root"

config="$root/config.json"
if [[ ! -f "$config" ]]; then
  echo "Missing $config (gitignored). Need GEMMA_MODEL_URL." >&2
  exit 1
fi
if ! grep -q '"GEMMA_MODEL_URL"' "$config"; then
  echo "$config has no GEMMA_MODEL_URL; the APK would pull from Hugging Face." >&2
  exit 1
fi

if command -v fvm >/dev/null 2>&1; then
  flutter=(fvm flutter)
else
  flutter=(flutter)
fi

# arm64 only (LiteRT FFI is arm64-v8a). Obfuscate + split-debug-info
# shrinks libapp.so; symbols land next to the APK for crash decoding.
# Native ML (.so) still dominates size — do not strip LiteRT / onnxruntime.
"${flutter[@]}" build apk --release \
  --target-platform android-arm64 \
  --obfuscate \
  --split-debug-info="$root/build/app/outputs/symbols" \
  --tree-shake-icons \
  --dart-define-from-file=config.json \
  "$@"

apk="$root/build/app/outputs/flutter-apk/app-release.apk"
echo "Built $apk ($(du -h "$apk" | awk '{print $1}'))"
