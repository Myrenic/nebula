# Optional: the cluster runs the addon straight from the ConfigMap-mounted
# source on a stock node image (see deployment.yaml). This Dockerfile mirrors
# that layout for local/manual builds.
FROM docker.io/library/node:22-alpine
WORKDIR /app
COPY src ./src
ENV PORT=7000
EXPOSE 7000
CMD ["node", "src/start.js"]
