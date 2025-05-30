#!/bin/bash

set -e

IMAGE_REPO="ghcr.io/snowflake-labs/polaris-cli-opencatalog-demo"
IMAGE_NAME="polaris-cli"
IMAGE_TAG="v0.10.0"
FULL_IMAGE_NAME="${IMAGE_REPO}/${IMAGE_NAME}:${IMAGE_TAG}"
## TODO
# SLIM_IMAGE_NAME="${IMAGE_REPO}/${IMAGE_NAME}:${IMAGE_TAG}-slim"

echo "Building Apache Polaris CLI Docker image..."
echo "Image: ${FULL_IMAGE_NAME}"

# Build original image
docker build --no-cache -t "${FULL_IMAGE_NAME}" -t "${IMAGE_REPO}/${IMAGE_NAME}:latest" .

# Check for docker-slim and install if needed
# if ! command -v docker-slim &> /dev/null; then
#     echo "Installing docker-slim..."
#     if [[ "$OSTYPE" == "darwin"* ]]; then
#         brew install docker-slim
#     else
#         echo "Please install docker-slim from https://dockerslim.com"
#         exit 1
#     fi
# fi

# Create slim version with enhanced options
# TODO: Fix this with right options
# echo "Creating slim version with docker-slim..."
# docker-slim build \
#     --target "${FULL_IMAGE_NAME}" \
#     --tag "${SLIM_IMAGE_NAME}" \
#     --http-probe=false \
#     --continue-after=1 \
#     --include-shell \
#     --include-exe \
#     --include-path "/app/polaris" \
#     --include-path "/app/polaris-venv" \
#     --include-path "/app/client/python" \
#     --include-path "/app/client/polaris" \
#     --cmd='polaris --help'

# Parse arguments
for arg in "$@"; do
  if [ "$arg" == "--push" ]; then
    push=true
    break
  fi
done

echo
echo "Build completed successfully!"
echo
echo "Original image:"
docker images "${FULL_IMAGE_NAME}" --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"
echo
echo "Slim image:"
docker images "${SLIM_IMAGE_NAME}" --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"

# Test both images
echo
echo "Testing images..."
echo "Testing original image:"
docker run --rm "${FULL_IMAGE_NAME}" polaris --help > /dev/null && echo "✅ Original image works" || echo "❌ Original image failed"

# echo "Testing slim image:"
# docker run --rm "${SLIM_IMAGE_NAME}" polaris --help > /dev/null && echo "✅ Slim image works" || echo "❌ Slim image failed"

if [ "${push:-false}" == true ]; then
    echo
    echo "Pushing Docker images to repository..."
    # docker push "${FULL_IMAGE_NAME}"
    # docker push "${SLIM_IMAGE_NAME}"
    docker push "${IMAGE_REPO}/${IMAGE_NAME}:latest"
    echo "✅ Images pushed successfully"
else
    echo
    echo "Skipping push. Use --push to push images to the repository."
fi

echo
echo "Usage:"
echo "  docker run --rm ${FULL_IMAGE_NAME} polaris --help"
# echo "  docker run --rm ${SLIM_IMAGE_NAME} polaris --help"