FROM node:22-bookworm-slim

WORKDIR /app

# better-sqlite3 needs a C++ toolchain if no prebuilt binary matches the image's
# platform/libc; keeping build tools in the final image trades a larger image
# for a Dockerfile that doesn't fight multi-stage native-module copying.
RUN apt-get update \
  && apt-get install -y --no-install-recommends python3 make g++ \
  && rm -rf /var/lib/apt/lists/*

COPY package.json package-lock.json* ./
RUN npm install

COPY tsconfig.json ./
COPY src ./src
RUN npm run build && npm prune --omit=dev

ENV NODE_ENV=production
EXPOSE 8080
VOLUME ["/app/data", "/app/secrets"]

CMD ["node", "dist/index.js"]
