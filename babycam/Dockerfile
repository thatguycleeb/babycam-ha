ARG BUILD_FROM
FROM $BUILD_FROM

RUN apk add --no-cache nodejs npm

WORKDIR /app
COPY app/package.json ./
RUN npm install --omit=dev --no-audit --no-fund
COPY app/ ./

CMD ["node", "/app/server.js"]
