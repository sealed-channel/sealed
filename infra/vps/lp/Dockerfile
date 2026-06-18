# Dockerfile for the Sealed landing page / top-up app (Next.js 16).
#
# Build context: the sealed-landing-page repo root, e.g.
#   docker build -f <sealed-repo>/infra/vps/lp/Dockerfile -t sealed-lp <lp-repo>
#
# Requires `output: "standalone"` in next.config.ts (additive one-liner for
# the LP dev — without it the runtime stage has no server.js).

FROM node:22-bookworm-slim AS build
WORKDIR /app
# NEXT_PUBLIC_* are inlined at build time by `next build`, so they must be
# present here (runtime env_file is too late for client-side code). Passed as
# build args from lp.env via the compose `build.args` block.
ARG NEXT_PUBLIC_APP_URL
ARG NEXT_PUBLIC_ALGO_NETWORK
ARG NEXT_PUBLIC_SEALED_APP_ID
ENV NEXT_PUBLIC_APP_URL=$NEXT_PUBLIC_APP_URL \
    NEXT_PUBLIC_ALGO_NETWORK=$NEXT_PUBLIC_ALGO_NETWORK \
    NEXT_PUBLIC_SEALED_APP_ID=$NEXT_PUBLIC_SEALED_APP_ID
COPY package.json package-lock.json ./
# better-sqlite3 is a native module — node-gyp toolchain needed at install.
RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++ \
    && rm -rf /var/lib/apt/lists/*
RUN npm ci
COPY . .
RUN npm run build

FROM node:22-bookworm-slim AS run
WORKDIR /app
ENV NODE_ENV=production
COPY --from=build /app/.next/standalone ./
COPY --from=build /app/.next/static ./.next/static
COPY --from=build /app/public ./public
USER node
EXPOSE 3000
CMD ["node", "server.js"]
