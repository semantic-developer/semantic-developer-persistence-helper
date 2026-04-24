#!/usr/bin/env bash
set -euo pipefail

# Build Linux helper binaries for linux/amd64 and linux/arm64 inside a
# swift:6.0-focal container (Ubuntu 20.04, glibc 2.31). The static Swift
# stdlib is linked in so the binary runs on hosts without a Swift runtime,
# and the older glibc baseline keeps it compatible with virtually every
# Linux server in service.
#
# Usage:
#   scripts/build-release-docker.sh v0.1.6 [amd64|arm64|all]
#
# Requires: docker (or compatible CLI) with buildx-style multi-arch support.
# On Apple Silicon, Colima with --vz-rosetta makes amd64 builds fast.

VERSION="${1:-}"
PLATFORMS_ARG="${2:-all}"

if [[ -z "$VERSION" ]]; then
  echo "Usage: scripts/build-release-docker.sh v0.1.6 [amd64|arm64|all]" >&2
  exit 64
fi

case "$PLATFORMS_ARG" in
  amd64) PLATFORMS=(linux/amd64) ;;
  arm64) PLATFORMS=(linux/arm64) ;;
  all)   PLATFORMS=(linux/amd64 linux/arm64) ;;
  *) echo "unknown platform selector: $PLATFORMS_ARG" >&2; exit 64 ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/latest-releases/$VERSION"
mkdir -p "$OUT_DIR"

IMAGE="swift:6.0-focal"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker CLI not found on PATH" >&2
  exit 1
fi

for platform in "${PLATFORMS[@]}"; do
  echo "==> Building for $platform"

  case "$platform" in
    linux/amd64) suffix="linux-x86_64" ;;
    linux/arm64) suffix="linux-arm64" ;;
    *) echo "unsupported platform $platform" >&2; exit 1 ;;
  esac

  # Each platform builds in its own .build dir so the two runs don't clobber
  # each other's intermediates.
  build_subdir=".build-docker-$suffix"

  docker run --rm \
    --platform "$platform" \
    -v "$ROOT_DIR":/src \
    -w /src \
    -e SWIFT_BUILD_PATH="/src/$build_subdir" \
    "$IMAGE" \
    bash -lc "
      set -euo pipefail
      swift --version
      swift build \
        -c release \
        --build-path '/src/$build_subdir' \
        --product semantic-developer-helper \
        -Xswiftc -static-stdlib
      cp '/src/$build_subdir/release/semantic-developer-helper' \
         '/src/latest-releases/$VERSION/semantic-developer-helper-$suffix'
      strip -s '/src/latest-releases/$VERSION/semantic-developer-helper-$suffix' || true
      ls -la '/src/latest-releases/$VERSION/semantic-developer-helper-$suffix'
      file '/src/latest-releases/$VERSION/semantic-developer-helper-$suffix'
    "
done

# Refresh SHA256SUMS and release notes covering whatever is now in the dir.
(
  cd "$OUT_DIR"
  shasum -a 256 semantic-developer-helper-* > SHA256SUMS

  ARTIFACT_LINES=""
  for f in semantic-developer-helper-*; do
    ARTIFACT_LINES+="- $f"$'\n'
  done

  cat > RELEASE_NOTES.md <<NOTES
# semantic-developer-helper $VERSION

Build date: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
Built in: $IMAGE (Ubuntu 20.04, glibc 2.31, -static-stdlib)

Artifacts:

$ARTIFACT_LINES

Checksums:

\`\`\`text
$(cat SHA256SUMS)
\`\`\`
NOTES
)

echo
echo "==> Release artifacts written to $OUT_DIR"
ls -la "$OUT_DIR"
