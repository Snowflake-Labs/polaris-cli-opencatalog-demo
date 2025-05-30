FROM python:3.11-alpine3.21

WORKDIR /app

# Install runtime dependencies first
RUN apk update && apk add --no-cache \
    bash \
    ca-certificates

# Install build dependencies, build, and clean up in one layer
RUN apk add --no-cache --virtual .build-deps \
    git \
    build-base \
    python3-dev \
    gcc \
    musl-dev \
    && git clone --depth 1 --branch v0.10.0 \
    https://github.com/kameshsampath/polaris.git \
    && python -m venv /app/polaris-venv \
    && . /app/polaris-venv/bin/activate \
    && pip install --upgrade pip \
    && pip install --no-cache-dir -e /app/polaris/client/python/ \
    && cp -r /app/polaris/client /app/client \
    && rm -rf /app/polaris \
    && apk del .build-deps \
    && rm -rf /var/cache/apk/* \
    && find /app/polaris-venv -type f -name "*.pyc" -delete \
    && find /app/polaris-venv -type d -name "__pycache__" -delete

# Create non-root user
RUN addgroup -S polaris && adduser -S polaris -G polaris
RUN chown -R polaris:polaris /app

# Create wrapper script
RUN printf "#!/bin/bash\n\nsource /app/polaris-venv/bin/activate\n\nexec python /app/client/python/cli/polaris_cli.py \"\$@\"\n\n" > /app/polaris && \
    chmod +x /app/polaris

USER polaris

ENV PATH="/app/polaris-venv/bin:/app:$PATH"
ENV VIRTUAL_ENV="/app/polaris-venv"
ENV PYTHONPATH="/app/client/python"
ENV SCRIPT_DIR="/app"

CMD ["polaris","--help"]

LABEL org.opencontainers.image.source=https://Snowflake-Labs/polaris-cli-opencatalog-demo.git