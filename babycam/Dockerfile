ARG BUILD_FROM=node:22-alpine
FROM $BUILD_FROM

WORKDIR /app
COPY app/package.json app/package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY app/ ./

CMD ["node", "/app/server.js"]
