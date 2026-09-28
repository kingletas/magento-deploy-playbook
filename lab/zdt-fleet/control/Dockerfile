# Where the arms run: bash, ssh, rsync, curl, the MariaDB client and Python 3.
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash openssh-client rsync curl mariadb-client python3 ca-certificates coreutils gawk procps \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash zdt \
    && mkdir -p /home/zdt/.ssh \
    && printf '%s\n' 'Host web1 web2 web3' '    User deploy' '    BatchMode yes' \
        '    StrictHostKeyChecking yes' > /home/zdt/.ssh/config \
    && mkdir -p /runs /lab-config \
    && chown -R zdt:zdt /home/zdt/.ssh /runs /lab-config \
    && chmod 700 /home/zdt/.ssh && chmod 600 /home/zdt/.ssh/config

COPY entrypoint.sh /usr/local/bin/zdtfleet-entrypoint
RUN chmod 755 /usr/local/bin/zdtfleet-entrypoint
ENTRYPOINT ["/usr/local/bin/zdtfleet-entrypoint"]
