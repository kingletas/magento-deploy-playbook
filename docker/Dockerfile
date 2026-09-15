# One image for every role in the fake fleet. The containers differ only by which
# inventory group they land in, because the playbook decides behaviour by group.
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# openssh-server and rsync, because the BUILDER has to SSH to the web hosts for
# the push in tasks/deploy/upload.yml. sudo and acl are for become/become_user.
RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server rsync git python3 python3-apt sudo acl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# The playbook connects as `ubuntu` and becomes root or www-data.
RUN useradd -m -s /bin/bash ubuntu \
    && echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ubuntu \
    && groupadd -f www-data 2>/dev/null || true \
    && id -u www-data >/dev/null 2>&1 || useradd -r -g www-data -s /usr/sbin/nologin www-data

# The tree the playbook expects, under site.base.
#
# Ownership matters: the build play sets no `become`, so the builder pipeline
# runs as ubuntu, and a tree owned by www-data fails the clone. ubuntu owns it
# with www-data as a group-writable group, so the build and the extract on the
# web hosts both work.
RUN mkdir -p /var/www/html/releases /var/www/html/archives /var/www/html/shared \
    && touch /var/www/html/shared/env.php \
    && chown -R ubuntu:www-data /var/www/html \
    && chmod -R g+w /var/www/html

# Fakes for the tools the build shells out to. They log their arguments so a test
# can assert on what ran, and exit 0 so orchestration is what is under test.
COPY fakes/ /usr/local/bin/
RUN chmod +x /usr/local/bin/composer /usr/local/bin/magento-fake \
             /usr/local/bin/docker /usr/local/bin/php /usr/local/bin/manipulus \
    # The service module has no systemd to talk to in a container, so it falls
    # back to sysv and shells out to /etc/init.d/<name>. Install the shims there
    # and drop them from PATH.
    && for f in /usr/local/bin/initd-*; do \
         svc="$(basename "$f" | sed 's/^initd-//')"; \
         install -m 0755 "$f" "/etc/init.d/${svc}"; \
         rm -f "$f"; \
       done

# The bind-mounted fixture repo's owner UID does not exist in the container, so
# git refuses it as "dubious ownership". Only ever a read-only fixture here.
RUN git config --system --add safe.directory '*'

# The fakes append to this as several different users, so it is world-writable:
# a permission error on the LOG must never be what fails a task.
RUN install -m 0666 /dev/null /tmp/build-log

# releases.links points into site.symlink_base, an EFS mount on a real fleet.
# The targets exist here so the links resolve rather than dangle, which is what
# production looks like and what verify-deploy.yml asserts on.
ENV SUITE_EFS=/mnt/efs/magento.example.com
RUN mkdir -p "${SUITE_EFS}/media" "${SUITE_EFS}/sitemaps" \
             "${SUITE_EFS}/magento_static_files/_cache" \
    && touch "${SUITE_EFS}/sitemap-products.xml" \
    && chown -R ubuntu:www-data /mnt/efs && chmod -R g+w /mnt/efs

RUN mkdir -p /var/run/sshd /home/ubuntu/.ssh && chmod 700 /home/ubuntu/.ssh
COPY keys/id_test.pub /home/ubuntu/.ssh/authorized_keys
COPY keys/id_test /home/ubuntu/.ssh/id_rsa
COPY keys/id_test.pub /home/ubuntu/.ssh/id_rsa.pub
# The builder rsyncs to the web hosts and must trust them without a prompt.
# These keys are generated per run and never leave the suite.
RUN printf 'Host *\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n' \
        > /home/ubuntu/.ssh/config \
    && chmod 600 /home/ubuntu/.ssh/authorized_keys /home/ubuntu/.ssh/id_rsa /home/ubuntu/.ssh/config \
    && chown -R ubuntu:ubuntu /home/ubuntu/.ssh

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
