# Thin derivative of the upstream Keep API image that carries the Git-managed
# workflows. Built and pushed by scripts/mirror-keep-images.sh; the tag is the
# upstream Keep version so the ECS task definition pins an exact release.
ARG KEEP_VERSION
FROM us-central1-docker.pkg.dev/keephq/keep/keep-api:${KEEP_VERSION}

# Loaded at startup through KEEP_WORKFLOWS_DIRECTORY (set by Terraform).
COPY workflows/ /opt/keep/workflows/
