#!/usr/bin/env bash
# Mirror the upstream Keep images into this account's ECR:
#   keep-api : rebuilt from keep/Dockerfile so that the Git-managed workflows are inside the image
#   keep-ui  : re-tagged as is
# Usage: KEEP_VERSION=0.50.0 ./scripts/mirror-keep-images.sh ap-northeast-1 alertpipe
set -euo pipefail

REGION="${1:?region}"
NAME="${2:?name prefix (var.name in tfvars)}"
: "${KEEP_VERSION:?set KEEP_VERSION to the upstream Keep tag}"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
UPSTREAM="us-central1-docker.pkg.dev/keephq/keep"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

docker build --platform linux/amd64 \
  --build-arg "KEEP_VERSION=${KEEP_VERSION}" \
  -t "${REGISTRY}/${NAME}/keep-api:${KEEP_VERSION}" \
  "${HERE}/keep"
docker push "${REGISTRY}/${NAME}/keep-api:${KEEP_VERSION}"

docker pull --platform linux/amd64 "${UPSTREAM}/keep-ui:${KEEP_VERSION}"
docker tag "${UPSTREAM}/keep-ui:${KEEP_VERSION}" "${REGISTRY}/${NAME}/keep-ui:${KEEP_VERSION}"
docker push "${REGISTRY}/${NAME}/keep-ui:${KEEP_VERSION}"

echo "pushed ${NAME}/keep-api:${KEEP_VERSION} and ${NAME}/keep-ui:${KEEP_VERSION} to ${REGISTRY}"
