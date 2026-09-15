# magepack, the browser-driven bundler, in a container. Needs a running store it
# can reach and a URL for every page type.
#
#   make magepack-image
#   # then set `bundler: magepack` in group_vars/all/build.yml
#
# Chromium comes from the distro. Puppeteer's own download pins a 2020 build
# whose URLs have been unreliable.
FROM node:20-bookworm-slim

ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true \
    PUPPETEER_SKIP_DOWNLOAD=true \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium

RUN apt-get update && apt-get install -y --no-install-recommends \
        chromium ca-certificates fonts-liberation \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g magepack@2.11.0 && npm cache clean --force

# --no-sandbox: Chromium's sandbox needs privileges a build container should not
# be given, and the page being rendered is your own store.
ENV CHROME_ARGS="--no-sandbox --disable-dev-shm-usage"

WORKDIR /app
ENTRYPOINT ["magepack"]
CMD ["--help"]
