# ------------------------------------------------------------------------------
# Sealed Indexer — production image (arm64, for Raspberry Pi 4B).
#
# Two-stage build: compile TypeScript with devDeps, ship only dist + prod deps.
# Image is intentionally slim so the Pi doesn't store multiple GB of node_modules
# on its SSD volume.
# ------------------------------------------------------------------------------

# ---------- Stage 1: build ----------
FROM --platform=linux/arm64 node:20-bookworm-slim AS build

WORKDIR /app

# Install deps first for better layer caching.
COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json tsconfig.scripts.json ./
COPY src ./src
COPY scripts ./scripts
RUN npm run build:all

# Prune devDependencies so the prod stage only copies what it needs.
RUN npm prune --omit=dev

# ---------- Stage 2: runtime ----------
FROM --platform=linux/arm64 node:20-bookworm-slim AS runtime

# Non-root runtime user. The node:*-slim images ship a `node` user (uid 1000);
# we use it instead of rolling our own.
WORKDIR /app
ENV NODE_ENV=production

COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/dist ./dist
COPY --chown=node:node package.json ./

# Compiled ops scripts (e.g. send_apns_test, import-legacy-usernames) ship in
# the image at /app/dist/scripts. Run with: docker compose exec sealed-indexer
# (No host mount — see docker-compose.yml.)

# /data holds the SQLite DB; the compose file mounts the SSD volume here.
RUN mkdir -p /data && chown node:node /data
VOLUME ["/data"]

USER node
EXPOSE 3000

CMD ["node", "dist/index.js"]
