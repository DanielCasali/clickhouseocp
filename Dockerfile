FROM registry.access.redhat.com/ubi8/ubi:latest

# Set environment variables
ENV CLICKHOUSE_VERSION=23.12.2.59

# Install required packages
RUN dnf update -y && \
    dnf install -y \
        curl \
        wget \
        tar \
        gzip \
        glibc \
        libstdc++ \
        ca-certificates \
        tzdata && \
    dnf clean all

# Create necessary directories with proper permissions
RUN mkdir -p /var/lib/clickhouse \
             /var/log/clickhouse-server \
             /etc/clickhouse-server \
             /etc/clickhouse-client \
             /usr/bin \
             /opt/clickhouse && \
    chmod -R 775 /var/lib/clickhouse \
                 /var/log/clickhouse-server \
                 /etc/clickhouse-server \
                 /etc/clickhouse-client \
                 /opt/clickhouse

# Download and install ClickHouse binaries
RUN cd /tmp && \
    wget -q "https://github.com/ClickHouse/ClickHouse/releases/download/v${CLICKHOUSE_VERSION}/clickhouse-common-static-${CLICKHOUSE_VERSION}-amd64.tgz" && \
    wget -q "https://github.com/ClickHouse/ClickHouse/releases/download/v${CLICKHOUSE_VERSION}/clickhouse-server-${CLICKHOUSE_VERSION}-amd64.tgz" && \
    wget -q "https://github.com/ClickHouse/ClickHouse/releases/download/v${CLICKHOUSE_VERSION}/clickhouse-client-${CLICKHOUSE_VERSION}-amd64.tgz" && \
    tar -xzf "clickhouse-common-static-${CLICKHOUSE_VERSION}-amd64.tgz" --strip-components=2 -C /usr/bin && \
    tar -xzf "clickhouse-server-${CLICKHOUSE_VERSION}-amd64.tgz" --strip-components=2 -C /usr/bin && \
    tar -xzf "clickhouse-client-${CLICKHOUSE_VERSION}-amd64.tgz" --strip-components=2 -C /usr/bin && \
    chmod +x /usr/bin/clickhouse* && \
    rm -rf /tmp/clickhouse-*.tgz

# Create default configuration files
RUN cat > /etc/clickhouse-server/config.xml << 'EOF'
<?xml version="1.0"?>
<yandex>
    <logger>
        <level>information</level>
        <log>/var/log/clickhouse-server/clickhouse-server.log</log>
        <errorlog>/var/log/clickhouse-server/clickhouse-server.err.log</errorlog>
        <size>1000M</size>
        <count>10</count>
    </logger>
    <http_port>8123</http_port>
    <tcp_port>9000</tcp_port>
    <mysql_port>9004</mysql_port>
    <postgresql_port>9005</postgresql_port>
    <listen_host>0.0.0.0</listen_host>
    <max_connections>4096</max_connections>
    <keep_alive_timeout>3</keep_alive_timeout>
    <max_concurrent_queries>100</max_concurrent_queries>
    <uncompressed_cache_size>8589934592</uncompressed_cache_size>
    <mark_cache_size>5368709120</mark_cache_size>
    <path>/var/lib/clickhouse/</path>
    <tmp_path>/var/lib/clickhouse/tmp/</tmp_path>
    <users_config>users.xml</users_config>
    <default_profile>default</default_profile>
    <default_database>default</default_database>
    <timezone>UTC</timezone>
    <mlock_executable>false</mlock_executable>
    <builtin_dictionaries_reload_interval>3600</builtin_dictionaries_reload_interval>
    <max_session_timeout>3600</max_session_timeout>
    <default_session_timeout>60</default_session_timeout>
    <query_log>
        <database>system</database>
        <table>query_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <flush_interval_milliseconds>7500</flush_interval_milliseconds>
    </query_log>
    <dictionaries_config>*_dictionary.xml</dictionaries_config>
    <compression>
        <case>
            <min_part_size>10000000000</min_part_size>
            <min_part_size_ratio>0.01</min_part_size_ratio>
            <method>lz4</method>
        </case>
    </compression>
    <networks>
        <ip>::/0</ip>
    </networks>
</yandex>
EOF

RUN cat > /etc/clickhouse-server/users.xml << 'EOF'
<?xml version="1.0"?>
<yandex>
    <profiles>
        <default>
            <max_memory_usage>10000000000</max_memory_usage>
            <use_uncompressed_cache>0</use_uncompressed_cache>
            <load_balancing>random</load_balancing>
        </default>
        <readonly>
            <readonly>1</readonly>
        </readonly>
    </profiles>
    <users>
        <default>
            <password></password>
            <networks>
                <ip>::/0</ip>
            </networks>
            <profile>default</profile>
            <quota>default</quota>
        </default>
    </users>
    <quotas>
        <default>
            <interval>
                <duration>3600</duration>
                <queries>0</queries>
                <errors>0</errors>
                <result_rows>0</result_rows>
                <read_rows>0</read_rows>
                <execution_time>0</execution_time>
            </interval>
        </default>
    </quotas>
</yandex>
EOF

# Create startup script
RUN cat > /opt/clickhouse/start.sh << 'EOF'
#!/bin/bash
set -e

# Create necessary directories if they don't exist
mkdir -p /var/lib/clickhouse/tmp
mkdir -p /var/log/clickhouse-server

# Ensure proper permissions
chmod -R 755 /var/lib/clickhouse
chmod -R 755 /var/log/clickhouse-server

# Start ClickHouse server
exec /usr/bin/clickhouse-server --config-file=/etc/clickhouse-server/config.xml
EOF

RUN chmod +x /opt/clickhouse/start.sh

# Set proper permissions for OpenShift compatibility
RUN chgrp -R 0 /var/lib/clickhouse \
               /var/log/clickhouse-server \
               /etc/clickhouse-server \
               /etc/clickhouse-client \
               /opt/clickhouse && \
    chmod -R g=u /var/lib/clickhouse \
                 /var/log/clickhouse-server \
                 /etc/clickhouse-server \
                 /etc/clickhouse-client \
                 /opt/clickhouse

# Expose ports
EXPOSE 8123 9000 9004 9005

# Use non-root user (OpenShift will override this anyway)
USER 1001

# Set working directory
WORKDIR /var/lib/clickhouse

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=30s --retries=3 \
  CMD curl -f http://localhost:8123/ping || exit 1

# Start ClickHouse
CMD ["/opt/clickhouse/start.sh"]
