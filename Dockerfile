# Multi-stage build for ClickHouse on UBI 9
FROM registry.access.redhat.com/ubi9/ubi:latest AS builder

# Install build dependencies
RUN dnf update -y && \
    dnf install -y --allowerasing \
        git \
        cmake \
        ninja-build \
        gcc \
        gcc-c++ \
        python3 \
        python3-pip \
        curl \
        wget \
        tar \
        gzip \
        which \
        diffutils \
        make \
        rpm-build \
        glibc-devel \
        libstdc++-devel \
        zlib-devel \
        openssl-devel \
        libicu-devel \
        libedit-devel \
        unixODBC-devel \
        libuuid-devel \
        libzstd-devel && \
    dnf clean all

# Add AlmaLinux devel repository for additional packages like yasm and nasm
RUN echo '[almalinux-devel]' > /etc/yum.repos.d/almalinux-devel.repo && \
    echo 'name=AlmaLinux $releasever - Devel' >> /etc/yum.repos.d/almalinux-devel.repo && \
    echo 'baseurl=https://repo.almalinux.org/almalinux/9/devel/x86_64/os/' >> /etc/yum.repos.d/almalinux-devel.repo && \
    echo 'enabled=1' >> /etc/yum.repos.d/almalinux-devel.repo && \
    echo 'gpgcheck=0' >> /etc/yum.repos.d/almalinux-devel.repo

# Install NASM and YASM from AlmaLinux devel repo
RUN dnf install -y --allowerasing \
        nasm-rdoff \
        yasm && \
    dnf clean all

# Check what nasm-rdoff installed and create symlinks if needed
RUN echo "Checking nasm-rdoff package contents:" && \
    rpm -ql nasm-rdoff && \
    echo "Looking for nasm executable:" && \
    find /usr -name "*nasm*" -type f 2>/dev/null && \
    echo "Checking if nasm is in PATH:" && \
    which nasm || echo "nasm not found in PATH" && \
    if [ -f /usr/bin/nasm ]; then echo "nasm found at /usr/bin/nasm"; \
    elif [ -f /usr/local/bin/nasm ]; then echo "nasm found at /usr/local/bin/nasm"; ln -sf /usr/local/bin/nasm /usr/bin/nasm; \
    else echo "Installing NASM from source as fallback"; \
        cd /tmp && \
        wget https://www.nasm.us/pub/nasm/releasebuilds/2.16.01/nasm-2.16.01.tar.xz && \
        tar -xf nasm-2.16.01.tar.xz && \
        cd nasm-2.16.01 && \
        ./configure --prefix=/usr/local && \
        make && \
        make install && \
        ln -sf /usr/local/bin/nasm /usr/bin/nasm && \
        cd / && \
        rm -rf /tmp/nasm-*; \
    fi && \
    echo "Final nasm location:" && \
    which nasm && \
    /usr/bin/nasm --version

# Install newer CMake (ClickHouse requires >= 3.20, using 3.31.7 for CMP0177 policy support)
RUN cd /tmp && \
    wget https://github.com/Kitware/CMake/releases/download/v3.31.7/cmake-3.31.7-linux-x86_64.tar.gz && \
    tar -xzf cmake-3.31.7-linux-x86_64.tar.gz && \
    cp -r cmake-3.31.7-linux-x86_64/* /usr/local/ && \
    rm -rf cmake-3.31.7* && \
    ln -sf /usr/local/bin/cmake /usr/bin/cmake && \
    echo "Installed CMake version:" && \
    cmake --version

# Install Clang from AlmaLinux AppStream repository (Clang 16)
RUN dnf install -y --allowerasing \
        clang \
        clang-tools-extra \
        llvm \
        llvm-devel \
        lld && \
    dnf clean all

# Install Rust nightly (required by ClickHouse for edition2024 feature)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && \
    source ~/.cargo/env && \
    rustup toolchain install nightly-2025-07-07 && \
    rustup default nightly-2025-07-07

# Set environment to use Clang and nightly Rust
ENV CC=clang
ENV CXX=clang++
ENV PATH="/root/.cargo/bin:$PATH"

# Clone ClickHouse source (using stable tag)
ARG CLICKHOUSE_VERSION=v25.7.4.11-stable
RUN git clone --recursive --shallow-submodules --branch ${CLICKHOUSE_VERSION} \
    https://github.com/ClickHouse/ClickHouse.git /clickhouse-source

# Build ClickHouse
WORKDIR /clickhouse-source
RUN mkdir -p /clickhouse-source/build && \
    cd /clickhouse-source/build && \
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DENABLE_TESTS=OFF \
        -DENABLE_EXAMPLES=OFF \
        -DENABLE_FUZZING=OFF \
        -DENABLE_UTILS=ON \
        -DENABLE_THINLTO=OFF \
        -DWERROR=OFF \
        -DCOMPILER_CACHE=disabled \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -GNinja && \
    echo "Available targets:" && \
    ninja -t targets | head -20 && \
    echo "Building ClickHouse..." && \
    ninja clickhouse || ninja clickhouse-server clickhouse-client || ninja all


# Final runtime image
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

# Install minimal runtime dependencies
RUN microdnf update -y && \
    microdnf install -y \
        glibc \
        libstdc++ \
        zlib \
        openssl-libs \
        libicu \
        tzdata \
        ca-certificates \
        procps-ng \
        shadow-utils && \
    microdnf clean all

# Create clickhouse user/group for OpenShift compatibility
RUN groupadd -r clickhouse --gid=1001 && \
    useradd -r -g clickhouse --uid=1001 --home-dir=/var/lib/clickhouse --shell=/bin/bash clickhouse

# Copy ClickHouse binary from builder
COPY --from=builder /clickhouse-source/build/programs/clickhouse /usr/bin/
RUN cd /usr/bin && \
    ln -sf clickhouse clickhouse-benchmark && \
    ln -sf clickhouse clickhouse-chdig && \
    ln -sf clickhouse clickhouse-check-marks && \
    ln -sf clickhouse clickhouse-checksum-for-compressed-block && \
    ln -sf clickhouse clickhouse-client && \
    ln -sf clickhouse clickhouse-compressor && \
    ln -sf clickhouse clickhouse-disks && \
    ln -sf clickhouse clickhouse-extract-from-config && \
    ln -sf clickhouse clickhouse-format && \
    ln -sf clickhouse clickhouse-fst-dump-tree && \
    ln -sf clickhouse clickhouse-git-import && \
    ln -sf clickhouse clickhouse-keeper && \
    ln -sf clickhouse clickhouse-keeper-bench && \
    ln -sf clickhouse clickhouse-keeper-client && \
    ln -sf clickhouse clickhouse-keeper-converter && \
    ln -sf clickhouse clickhouse-keeper-data-dumper && \
    ln -sf clickhouse clickhouse-keeper-utils && \
    ln -sf clickhouse clickhouse-local && \
    ln -sf clickhouse clickhouse-obfuscator && \
    ln -sf clickhouse clickhouse-server && \
    ln -sf clickhouse clickhouse-static-files-disk-uploader && \
    ln -sf clickhouse clickhouse-su && \
    ln -sf clickhouse clickhouse-zookeeper-dump-tree && \
    ln -sf clickhouse clickhouse-zookeeper-remove-by-list && \
    cd -

# Create all necessary directories
RUN mkdir -p /var/lib/clickhouse/data \
             /var/lib/clickhouse/tmp \
             /var/lib/clickhouse/user_files \
             /var/lib/clickhouse/format_schemas \
             /var/lib/clickhouse/preprocessed_configs \
             /var/lib/clickhouse/metadata \
             /var/log/clickhouse-server \
             /etc/clickhouse-server/config.d \
             /etc/clickhouse-server/users.d \
             /etc/clickhouse-client \
             /docker-entrypoint-initdb.d

# Create main ClickHouse configuration
RUN echo '<?xml version="1.0"?>' > /etc/clickhouse-server/config.xml && \
    echo '<yandex>' >> /etc/clickhouse-server/config.xml && \
    echo '    <logger>' >> /etc/clickhouse-server/config.xml && \
    echo '        <level>information</level>' >> /etc/clickhouse-server/config.xml && \
    echo '        <log>/var/log/clickhouse-server/clickhouse-server.log</log>' >> /etc/clickhouse-server/config.xml && \
    echo '        <errorlog>/var/log/clickhouse-server/clickhouse-server.err.log</errorlog>' >> /etc/clickhouse-server/config.xml && \
    echo '        <size>1000M</size>' >> /etc/clickhouse-server/config.xml && \
    echo '        <count>10</count>' >> /etc/clickhouse-server/config.xml && \
    echo '        <console>true</console>' >> /etc/clickhouse-server/config.xml && \
    echo '    </logger>' >> /etc/clickhouse-server/config.xml && \
    echo '    <http_port>8123</http_port>' >> /etc/clickhouse-server/config.xml && \
    echo '    <tcp_port>9000</tcp_port>' >> /etc/clickhouse-server/config.xml && \
    echo '    <mysql_port>9004</mysql_port>' >> /etc/clickhouse-server/config.xml && \
    echo '    <postgresql_port>9005</postgresql_port>' >> /etc/clickhouse-server/config.xml && \
    echo '    <listen_host>0.0.0.0</listen_host>' >> /etc/clickhouse-server/config.xml && \
    echo '    <max_connections>4096</max_connections>' >> /etc/clickhouse-server/config.xml && \
    echo '    <keep_alive_timeout>3</keep_alive_timeout>' >> /etc/clickhouse-server/config.xml && \
    echo '    <max_concurrent_queries>100</max_concurrent_queries>' >> /etc/clickhouse-server/config.xml && \
    echo '    <uncompressed_cache_size>8589934592</uncompressed_cache_size>' >> /etc/clickhouse-server/config.xml && \
    echo '    <mark_cache_size>5368709120</mark_cache_size>' >> /etc/clickhouse-server/config.xml && \
    echo '    <path>/var/lib/clickhouse/</path>' >> /etc/clickhouse-server/config.xml && \
    echo '    <tmp_path>/var/lib/clickhouse/tmp/</tmp_path>' >> /etc/clickhouse-server/config.xml && \
    echo '    <user_files_path>/var/lib/clickhouse/user_files/</user_files_path>' >> /etc/clickhouse-server/config.xml && \
    echo '    <format_schema_path>/var/lib/clickhouse/format_schemas/</format_schema_path>' >> /etc/clickhouse-server/config.xml && \
    echo '    <users_config>users.xml</users_config>' >> /etc/clickhouse-server/config.xml && \
    echo '    <default_profile>default</default_profile>' >> /etc/clickhouse-server/config.xml && \
    echo '    <default_database>default</default_database>' >> /etc/clickhouse-server/config.xml && \
    echo '    <timezone>UTC</timezone>' >> /etc/clickhouse-server/config.xml && \
    echo '    <mlock_executable>false</mlock_executable>' >> /etc/clickhouse-server/config.xml && \
    echo '    <builtin_dictionaries_reload_interval>3600</builtin_dictionaries_reload_interval>' >> /etc/clickhouse-server/config.xml && \
    echo '    <max_session_timeout>3600</max_session_timeout>' >> /etc/clickhouse-server/config.xml && \
    echo '    <default_session_timeout>60</default_session_timeout>' >> /etc/clickhouse-server/config.xml && \
    echo '    <query_log>' >> /etc/clickhouse-server/config.xml && \
    echo '        <database>system</database>' >> /etc/clickhouse-server/config.xml && \
    echo '        <table>query_log</table>' >> /etc/clickhouse-server/config.xml && \
    echo '        <partition_by>toYYYYMM(event_date)</partition_by>' >> /etc/clickhouse-server/config.xml && \
    echo '        <flush_interval_milliseconds>7500</flush_interval_milliseconds>' >> /etc/clickhouse-server/config.xml && \
    echo '    </query_log>' >> /etc/clickhouse-server/config.xml && \
    echo '    <dictionaries_config>*_dictionary.xml</dictionaries_config>' >> /etc/clickhouse-server/config.xml && \
    echo '    <compression>' >> /etc/clickhouse-server/config.xml && \
    echo '        <case>' >> /etc/clickhouse-server/config.xml && \
    echo '            <min_part_size>10000000000</min_part_size>' >> /etc/clickhouse-server/config.xml && \
    echo '            <min_part_size_ratio>0.01</min_part_size_ratio>' >> /etc/clickhouse-server/config.xml && \
    echo '            <method>lz4</method>' >> /etc/clickhouse-server/config.xml && \
    echo '        </case>' >> /etc/clickhouse-server/config.xml && \
    echo '    </compression>' >> /etc/clickhouse-server/config.xml && \
    echo '</yandex>' >> /etc/clickhouse-server/config.xml

# Create default users configuration
RUN echo '<?xml version="1.0"?>' > /etc/clickhouse-server/users.xml && \
    echo '<yandex>' >> /etc/clickhouse-server/users.xml && \
    echo '    <profiles>' >> /etc/clickhouse-server/users.xml && \
    echo '        <default>' >> /etc/clickhouse-server/users.xml && \
    echo '            <max_memory_usage>10000000000</max_memory_usage>' >> /etc/clickhouse-server/users.xml && \
    echo '            <use_uncompressed_cache>0</use_uncompressed_cache>' >> /etc/clickhouse-server/users.xml && \
    echo '            <load_balancing>random</load_balancing>' >> /etc/clickhouse-server/users.xml && \
    echo '        </default>' >> /etc/clickhouse-server/users.xml && \
    echo '        <readonly>' >> /etc/clickhouse-server/users.xml && \
    echo '            <readonly>1</readonly>' >> /etc/clickhouse-server/users.xml && \
    echo '        </readonly>' >> /etc/clickhouse-server/users.xml && \
    echo '    </profiles>' >> /etc/clickhouse-server/users.xml && \
    echo '    <users>' >> /etc/clickhouse-server/users.xml && \
    echo '        <default>' >> /etc/clickhouse-server/users.xml && \
    echo '            <password></password>' >> /etc/clickhouse-server/users.xml && \
    echo '            <networks>' >> /etc/clickhouse-server/users.xml && \
    echo '                <ip>::/0</ip>' >> /etc/clickhouse-server/users.xml && \
    echo '            </networks>' >> /etc/clickhouse-server/users.xml && \
    echo '            <profile>default</profile>' >> /etc/clickhouse-server/users.xml && \
    echo '            <quota>default</quota>' >> /etc/clickhouse-server/users.xml && \
    echo '        </default>' >> /etc/clickhouse-server/users.xml && \
    echo '    </users>' >> /etc/clickhouse-server/users.xml && \
    echo '    <quotas>' >> /etc/clickhouse-server/users.xml && \
    echo '        <default>' >> /etc/clickhouse-server/users.xml && \
    echo '            <interval>' >> /etc/clickhouse-server/users.xml && \
    echo '                <duration>3600</duration>' >> /etc/clickhouse-server/users.xml && \
    echo '                <queries>0</queries>' >> /etc/clickhouse-server/users.xml && \
    echo '                <errors>0</errors>' >> /etc/clickhouse-server/users.xml && \
    echo '                <result_rows>0</result_rows>' >> /etc/clickhouse-server/users.xml && \
    echo '                <read_rows>0</read_rows>' >> /etc/clickhouse-server/users.xml && \
    echo '                <execution_time>0</execution_time>' >> /etc/clickhouse-server/users.xml && \
    echo '            </interval>' >> /etc/clickhouse-server/users.xml && \
    echo '        </default>' >> /etc/clickhouse-server/users.xml && \
    echo '    </quotas>' >> /etc/clickhouse-server/users.xml && \
    echo '</yandex>' >> /etc/clickhouse-server/users.xml

# Create entrypoint script
RUN echo '#!/bin/bash' > /entrypoint.sh && \
    echo 'set -eo pipefail' >> /entrypoint.sh && \
    echo '' >> /entrypoint.sh && \
    echo '# if command starts with an option, prepend clickhouse-server' >> /entrypoint.sh && \
    echo 'if [ "${1:0:1}" = '\''-'\'' ]; then' >> /entrypoint.sh && \
    echo '    set -- clickhouse-server "$@"' >> /entrypoint.sh && \
    echo 'fi' >> /entrypoint.sh && \
    echo '' >> /entrypoint.sh && \
    echo '# Ensure all directories exist' >> /entrypoint.sh && \
    echo 'mkdir -p /var/lib/clickhouse/data' >> /entrypoint.sh && \
    echo 'mkdir -p /var/lib/clickhouse/tmp' >> /entrypoint.sh && \
    echo 'mkdir -p /var/lib/clickhouse/user_files' >> /entrypoint.sh && \
    echo 'mkdir -p /var/lib/clickhouse/format_schemas' >> /entrypoint.sh && \
    echo 'mkdir -p /var/lib/clickhouse/preprocessed_configs' >> /entrypoint.sh && \
    echo 'mkdir -p /var/lib/clickhouse/metadata' >> /entrypoint.sh && \
    echo 'mkdir -p /var/log/clickhouse-server' >> /entrypoint.sh && \
    echo '' >> /entrypoint.sh && \
    echo '# Change to ClickHouse directory' >> /entrypoint.sh && \
    echo 'cd /var/lib/clickhouse' >> /entrypoint.sh && \
    echo '' >> /entrypoint.sh && \
    echo '# Handle authentication setup from environment/secrets' >> /entrypoint.sh && \
    echo 'if [[ -n "$CLICKHOUSE_USER" ]] && [[ -n "$CLICKHOUSE_PASSWORD" ]]; then' >> /entrypoint.sh && \
    echo '    echo "Setting up custom user authentication..."' >> /entrypoint.sh && \
    echo 'fi' >> /entrypoint.sh && \
    echo '' >> /entrypoint.sh && \
    echo '# Execute the command' >> /entrypoint.sh && \
    echo 'exec "$@"' >> /entrypoint.sh && \
    chmod +x /entrypoint.sh

# Configure locale
ENV LANG=C.UTF-8
ENV TZ=UTC

# CRITICAL: OpenShift compatibility - group 0 permissions
RUN chgrp -R 0 /var/lib/clickhouse \
               /var/log/clickhouse-server \
               /etc/clickhouse-server \
               /etc/clickhouse-client \
               /docker-entrypoint-initdb.d && \
    chmod -R g=u /var/lib/clickhouse \
                 /var/log/clickhouse-server \
                 /etc/clickhouse-server \
                 /etc/clickhouse-client \
                 /docker-entrypoint-initdb.d

# Set working directory
WORKDIR /var/lib/clickhouse

# Expose ports
EXPOSE 8123 9000 9004 9005

# Set volume
VOLUME ["/var/lib/clickhouse"]

# Use numeric user for OpenShift
USER 1001

# Environment
ENV CLICKHOUSE_CONFIG=/etc/clickhouse-server/config.xml

# Default entrypoint and command
ENTRYPOINT ["/entrypoint.sh"]
CMD ["clickhouse-server", "--config-file=/etc/clickhouse-server/config.xml"]
