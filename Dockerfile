FROM ubuntu:22.04

# Prevent interactive prompts during package installation
ARG DEBIAN_FRONTEND=noninteractive

# ARG for quick switch to a given ubuntu mirror
ARG apt_archive="http://archive.ubuntu.com"

# ClickHouse version and repository settings
ARG REPO_CHANNEL="stable"
ARG REPOSITORY="deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg] https://packages.clickhouse.com/deb ${REPO_CHANNEL} main"
ARG VERSION="25.7.4.11"
ARG PACKAGES="clickhouse-client clickhouse-server clickhouse-common-static"

# Create clickhouse user/group with fixed uid/gid for OpenShift compatibility
# Important: Use GID 1001 and group 0 (root) for OpenShift
RUN sed -i "s|http://archive.ubuntu.com|${apt_archive}|g" /etc/apt/sources.list \
    && groupadd -r clickhouse --gid=1001 \
    && useradd -r -g clickhouse --uid=1001 --home-dir=/var/lib/clickhouse --shell=/bin/bash clickhouse \
    && apt-get update \
    && apt-get install --yes --no-install-recommends \
        busybox \
        ca-certificates \
        locales \
        tzdata \
        wget \
        dirmngr \
        gnupg2 \
    && busybox --install -s \
    && rm -rf /var/lib/apt/lists/* /var/cache/debconf /tmp/*

# Install ClickHouse from the official repository
RUN mkdir -p /etc/apt/sources.list.d \
    && GNUPGHOME=$(mktemp -d) \
    && GNUPGHOME="$GNUPGHOME" gpg --batch --no-default-keyring \
        --keyring /usr/share/keyrings/clickhouse-keyring.gpg \
        --keyserver hkp://keyserver.ubuntu.com:80 \
        --recv-keys 3a9ea1193a97b548be1457d48919f6bd2b48d754 \
    && rm -rf "$GNUPGHOME" \
    && chmod +r /usr/share/keyrings/clickhouse-keyring.gpg \
    && echo "${REPOSITORY}" > /etc/apt/sources.list.d/clickhouse.list \
    && echo "Installing ClickHouse from repository: ${REPOSITORY}" \
    && apt-get update \
    && for package in ${PACKAGES}; do \
        packages="${packages} ${package}=${VERSION}" \
    ; done \
    && apt-get install --yes --no-install-recommends ${packages} \
    && rm -rf /var/lib/apt/lists/* /var/cache/debconf /tmp/* \
    && apt-get autoremove --purge -yq dirmngr gnupg2

# Post-install setup and OpenShift compatibility
RUN clickhouse-local -q 'SELECT * FROM system.build_options' \
    && mkdir -p /var/lib/clickhouse /var/log/clickhouse-server /etc/clickhouse-server /etc/clickhouse-client \
    && mkdir /docker-entrypoint-initdb.d

# Configure locale and timezone
RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV TZ=UTC

# Create default configuration for OpenShift
RUN cat > /etc/clickhouse-server/config.d/docker_related_config.xml << 'XMLEOF'
<yandex>
    <!-- Listen for connections from anywhere -->
    <listen_host>0.0.0.0</listen_host>
    <listen_host>::</listen_host>
    
    <!-- Don't exit on SIGPIPE -->
    <listen_try>1</listen_try>
    
    <!-- Allow empty password for default user -->
    <users>
        <default>
            <password></password>
            <networks>
                <ip>::/0</ip>
            </networks>
        </default>
    </users>
    
    <!-- Logging configuration -->
    <logger>
        <console>true</console>
        <level>information</level>
    </logger>
</yandex>
XMLEOF

# Create entrypoint script
RUN cat > /entrypoint.sh << 'SCRIPTEOF'
#!/bin/bash
set -eo pipefail
shopt -s nullglob

# if command starts with an option, prepend clickhouse-server
if [ "${1:0:1}" = '-' ]; then
    set -- clickhouse-server "$@"
fi

# allow the container to be started with `--user`
if [[ "$1" = 'clickhouse-server' ]] && [[ "$(id -u)" = '0' ]]; then
    # if running as root, ensure directories exist and have correct ownership
    mkdir -p /var/lib/clickhouse /var/log/clickhouse-server
    # change ownership only if we're root
    chown -R clickhouse:clickhouse /var/lib/clickhouse /var/log/clickhouse-server /etc/clickhouse-server /etc/clickhouse-client
    # if CLICKHOUSE_PASSWORD is set, update the configuration
    if [[ -n "$CLICKHOUSE_PASSWORD" ]]; then
        echo "Setting up authentication..."
        # This would be handled by our ConfigMaps/Secrets in Kubernetes
    fi
    
    exec gosu clickhouse "$@"
fi

# if not root or not clickhouse-server, just exec the command
exec "$@"
SCRIPTEOF

# Install gosu for proper user switching (needed for entrypoint)
RUN apt-get update \
    && apt-get install -y --no-install-recommends gosu \
    && rm -rf /var/lib/apt/lists/* \
    && gosu nobody true

# Make entrypoint executable
RUN chmod +x /entrypoint.sh

# CRITICAL: OpenShift compatibility - make everything group-writable
# This allows OpenShift to assign any UID while keeping gid=0 (root group)
RUN chgrp -R 0 /var/lib/clickhouse /var/log/clickhouse-server /etc/clickhouse-server /etc/clickhouse-client /docker-entrypoint-initdb.d \
    && chmod -R g=u /var/lib/clickhouse /var/log/clickhouse-server /etc/clickhouse-server /etc/clickhouse-client /docker-entrypoint-initdb.d

# Expose standard ClickHouse ports
EXPOSE 9000 8123 9009

# Set volumes
VOLUME ["/var/lib/clickhouse"]

# Environment variables
ENV CLICKHOUSE_CONFIG=/etc/clickhouse-server/config.xml

# Use numeric user ID for better OpenShift compatibility
USER 1001

# Default command
ENTRYPOINT ["/entrypoint.sh"]
CMD ["clickhouse-server"]
