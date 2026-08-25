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

"${flutter[@]}" build apk --release --dart-define-from-file=config.json "$@"

echo "Built $root/build/app/outputs/flutter-apk/app-release.apk"
