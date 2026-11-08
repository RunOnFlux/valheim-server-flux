# Valheim server image for Flux.
#
# A thin layer over the community Valheim server image (Apache-2.0): same game, same environment
# variables, same supervisor layout. What it adds is a world guard that runs before every launch
# of the server (see README.md), and a base that moves only when WE move it.
#
# The base is pinned by upstream release tag. The nodes' own `lloesche/valheim-server:latest`
# is a legacy mirror that is re-pushed on every upstream release, and FluxOS soft-redeploys a
# server (players kicked) every time a tag's digest moves.
ARG BASE_TAG=1.4.1
FROM ghcr.io/community-valheim-tools/valheim-server:${BASE_TAG}

ARG BASE_TAG=1.4.1
ARG FLUX_IMAGE_VERSION=dev
LABEL org.opencontainers.image.title="valheim-server-flux" \
      org.opencontainers.image.description="Valheim dedicated server for FluxCloud, with a world guard" \
      org.opencontainers.image.licenses="Apache-2.0" \
      com.runonflux.base-tag="${BASE_TAG}" \
      com.runonflux.image-version="${FLUX_IMAGE_VERSION}"

# supervisor starts /usr/local/bin/valheim-server; keep the upstream script and put the guard in front.
RUN mv /usr/local/bin/valheim-server /usr/local/bin/valheim-server.upstream
COPY scripts/flux-world-guard /usr/local/bin/flux-world-guard
COPY scripts/flux-valheim-server /usr/local/bin/valheim-server
RUN chmod 0755 /usr/local/bin/flux-world-guard /usr/local/bin/valheim-server \
 && python3 -c "import ast;ast.parse(open('/usr/local/bin/flux-world-guard').read())"
