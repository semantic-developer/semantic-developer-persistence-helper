#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: scripts/build-release.sh v0.1.0" >&2
  exit 64
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/latest-releases/$VERSION"
mkdir -p "$OUT_DIR"

cd "$ROOT_DIR"

swift build -c release --product semantic-developer-helper

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  arm64) PLATFORM_SUFFIX="macos-arm64" ;;
  x86_64) PLATFORM_SUFFIX="macos-x86_64" ;;
  *) PLATFORM_SUFFIX="macos-$HOST_ARCH" ;;
esac

cp ".build/release/semantic-developer-helper" "$OUT_DIR/semantic-developer-helper-$PLATFORM_SUFFIX"

(
  cd "$OUT_DIR"
  shasum -a 256 semantic-developer-helper-* > SHA256SUMS
)

cat > "$OUT_DIR/RELEASE_NOTES.md" <<NOTES
# semantic-developer-helper $VERSION

Build date: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

Artifacts:

- semantic-developer-helper-$PLATFORM_SUFFIX

Checksums:

\`\`\`text
$(cat "$OUT_DIR/SHA256SUMS")
\`\`\`
NOTES

echo "Release artifacts written to $OUT_DIR"
