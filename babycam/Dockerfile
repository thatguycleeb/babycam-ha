ARG BUILD_FROM=ghcr.io/home-assistant/base:latest
FROM $BUILD_FROM

RUN apk add --no-cache nodejs npm

WORKDIR /app
COPY app/package.json app/package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY app/ ./

CMD ["node", "/app/server.js"]
