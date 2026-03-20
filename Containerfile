# SPDX-License-Identifier: PMPL-1.0-or-later
# Lightweight MCP stdio bridge for inspection and deployment.
# Runs only the Node.js MCP bridge (zero dependencies).
# The bridge responds to MCP initialize + tools/list with the full
# cartridge tool manifest.
#
# For the full production image with Zig FFI + V adapter, use:
#   podman build -f container/Containerfile .
#
# Usage:
#   podman build -t boj-server:latest .
#   echo '{"jsonrpc":"2.0","id":1,"method":"initialize",...}' | podman run -i boj-server

FROM node:22-slim

LABEL org.opencontainers.image.title="Bundle of Joy Server (MCP Bridge)" \
      org.opencontainers.image.description="MCP stdio transport for BoJ cartridge toolkit" \
      org.opencontainers.image.url="https://github.com/hyperpolymath/boj-server" \
      org.opencontainers.image.source="https://github.com/hyperpolymath/boj-server" \
      org.opencontainers.image.vendor="hyperpolymath" \
      org.opencontainers.image.licenses="PMPL-1.0-or-later" \
      org.opencontainers.image.authors="Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>"

WORKDIR /app

COPY package.json /app/
COPY mcp-bridge/ /app/mcp-bridge/

# No npm install needed — zero dependencies
USER node

ENTRYPOINT ["node", "mcp-bridge/main.js"]
