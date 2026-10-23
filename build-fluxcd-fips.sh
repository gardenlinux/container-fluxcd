#!/usr/bin/env bash
set -euo pipefail

# --- configuration -----------------------------------------------------------

REPO_URL="${REPO_URL:-https://github.com/fluxcd/flux2}"
BASE_IMAGE="${BASE_IMAGE:-ghcr.io/gardenlinux/gardenlinux/fips:1877.22}"
WORKDIR="${WORKDIR:-./.build/fluxcd-fips-build}"
IMAGE_NAME="${IMAGE_NAME:-gl-fips-fluxcd}"
ARCH="${ARCH:-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')}"
VERSION="${VERSION:-2.9.6}"
UPSTREAM_GIT_SHA="${UPSTREAM_GIT_SHA:-b9c17924adb533d3617ec7de97a7b0f4acc07b39}"
GO_IMAGE="${GO_IMAGE:-golang:1.26-bookworm}"
KUSTOMIZE_VERSION="${KUSTOMIZE_VERSION:-5.6.0}"

# --- prerequisites -----------------------------------------------------------

check_tool() { command -v "$1" &>/dev/null || { echo "error: $1 not found" >&2; exit 1; }; }
check_tool git
check_tool docker
docker buildx version &>/dev/null || { echo "error: docker buildx not available" >&2; exit 1; }

# --- buildx driver -----------------------------------------------------------

if ! docker buildx inspect fips-builder &>/dev/null; then
    docker buildx create --name fips-builder --driver docker-container
fi
docker buildx use fips-builder

# --- checkout ----------------------------------------------------------------

CLONE_DIR=".build/fips-port-fluxcd"
if [ ! -d "${CLONE_DIR}" ]; then
    git clone "${REPO_URL}" "${CLONE_DIR}"
fi
git -C "${CLONE_DIR}" checkout "v${VERSION}"

mkdir -p "${WORKDIR}"

# --- generate Dockerfile.fips ------------------------------------------------

cat > "${WORKDIR}/Dockerfile.fips" <<DOCKERFILE
ARG GO_IMAGE=golang:1.26-bookworm
ARG BASE_IMAGE=ghcr.io/gardenlinux/gardenlinux/fips:1877.22

FROM --platform=\$BUILDPLATFORM \${GO_IMAGE} AS builder
ARG ARCH
ARG VERSION
ARG KUSTOMIZE_VERSION
ARG UPSTREAM_GIT_SHA

WORKDIR /src
COPY . .

# Install kustomize — needed to generate the embedded manifests before go build
RUN GOTOOLCHAIN=auto GOARCH=\${ARCH} go install sigs.k8s.io/kustomize/kustomize/v5@v\${KUSTOMIZE_VERSION}

# Generate embedded manifests (bundle.sh calls kustomize build for each controller)
RUN ./manifests/scripts/bundle.sh
RUN touch cmd/flux/.manifests.done

# Build the flux CLI binary
RUN CGO_ENABLED=0 GOARCH=\${ARCH} go build \\
    -ldflags "-s -w -X main.VERSION=\${VERSION}" \\
    -o /flux ./cmd/flux

FROM \${BASE_IMAGE}
ARG UPSTREAM_GIT_SHA
LABEL org.opencontainers.image.description="A FIPS-enabled Flux CLI image"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.revision="\${UPSTREAM_GIT_SHA}"
COPY --from=builder /flux /usr/local/bin/flux
ENV GODEBUG=fips140=only
USER 65534:65534
ENTRYPOINT ["/usr/local/bin/flux"]
DOCKERFILE

# --- build -------------------------------------------------------------------

docker buildx build \
    --platform "linux/${ARCH}" \
    --build-arg ARCH="${ARCH}" \
    --build-arg VERSION="${VERSION}" \
    --build-arg GO_IMAGE="${GO_IMAGE}" \
    --build-arg BASE_IMAGE="${BASE_IMAGE}" \
    --build-arg KUSTOMIZE_VERSION="${KUSTOMIZE_VERSION}" \
    --build-arg UPSTREAM_GIT_SHA="${UPSTREAM_GIT_SHA}" \
    --load \
    --tag "${IMAGE_NAME}:${VERSION}-${ARCH}" \
    -f "${WORKDIR}/Dockerfile.fips" \
    "${CLONE_DIR}"

# --- report ------------------------------------------------------------------

echo "Built: ${IMAGE_NAME}:${VERSION}-${ARCH}"
