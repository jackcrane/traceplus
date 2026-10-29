FROM node:22-slim
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-fund --no-audit
COPY src ./src
COPY public ./public
# The web UI must be reachable from outside the container.
ENV HOST=0.0.0.0 NODE_ENV=production
EXPOSE 4400
CMD ["node", "src/main.js"]
