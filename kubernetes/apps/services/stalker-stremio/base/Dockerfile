# not-applied: local-build convenience only. The cluster does not build or run
# this image: it mounts src/ from a ConfigMap onto a stock node image and runs
# the entry point from there (see deployment.yaml), so nothing renders this
# Dockerfile. Kept because building it is the quickest way to run the addon
# outside the cluster, and pinned to the same node release the Deployment uses.
FROM docker.io/library/node:24.21.0-alpine3.24
WORKDIR /app
COPY src ./src
ENV PORT=7000
EXPOSE 7000
CMD ["node", "src/start.js"]
