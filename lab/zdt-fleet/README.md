# The zero-downtime lab fleet

**A real Magento Open Source fleet in containers, built so the arms in `bin/zdt-arm` can run against something that meets [issue #5](https://github.com/kingletas/magento-deploy-playbook/issues/5)'s conditions.** Three web nodes reached over ssh, a load balancer with a health check, a primary database with a live replica, and a control container the arms run from. Nothing here is faked: `php`, `bin/magento` and MariaDB are the real ones, unlike the six-container suite in `docker/`, which fakes Magento on purpose.

It runs on one Docker host. Every container has a CPU and memory limit, and nothing publishes a port except the load balancer, on `127.0.0.1`.

## What runs

| Service | Image | What it is | CPU | Memory |
|---|---|---|---|---|
| `db-primary` | `mariadb:11.4` | The primary. Binary log in row format, GTID, `server_id` 1 | 0.75 | 2 GiB |
| `db-replica` | `mariadb:11.4` | Replicates the primary by GTID (`MASTER_USE_GTID=slave_pos`), `read_only`, `server_id` 2 | 0.5 | 1.5 GiB |
| `opensearch` | `opensearchproject/opensearch:2.19.6` | Search, single node, security plugin off, heap 1 GiB | 0.75 | 2 GiB |
| `valkey` | `valkey/valkey:8` | Cache, full-page cache and sessions, one database each | 0.25 | 512 MiB |
| `web1`, `web2`, `web3` | built here, `zdtfleet-web` | nginx, PHP-FPM 8.4 and sshd in one container, as a web server would have them | 0.5 each | 1.25 GiB each |
| `lb` | `haproxy:3.2.24-alpine` | Round robin over the three nodes, active check on `/health_check.php` every 2 s | 0.1 | 128 MiB |
| `control` | built here, `zdtfleet-control` | Where the arms run: bash, ssh, rsync, curl, the MariaDB client, Python 3 | 0.15 | 512 MiB |
| `builder` | `zdtfleet-web` | Builds release tarballs. Compose profile `build`, so it runs only when called, with no network | 1.0 | 3 GiB |

**Total while the fleet runs: 4.0 CPUs and 10.25 GiB.** The builder runs only between arms, never during one. The host's other work keeps the rest.

Compose project name: **`zdtfleet`**. Every volume, network and container carries it, so the fleet is listed and removed by that label alone.

## A web node

Laid out the way `bin/zdt-arm` expects (`ZDT_RELEASES_DIR` and `ZDT_CURRENT_LINK` at their defaults):

```text
/var/www/magento/
  releases/<label>/        one unpacked release per label; var/ is per release
  current -> releases/<label>
  shared/app/etc/env.php   this node's env.php; each release links app/etc/env.php here
  shared/pub/media/        the media volume, shared by all three nodes
  zdt-snapshots/           database snapshots (web1 only)
```

**Each node keeps `/var/www/magento` on its own volume**, so its releases and its `env.php` survive a restart. A release reaches a node only the way the arms send one: rsync from `control`.

- **nginx** serves `root $realpath_root/pub` under `/var/www/magento/current`, so a relinked `current` takes effect on the next request without a reload. `fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name`, and `DOCUMENT_ROOT $realpath_root`.
- **PHP-FPM 8.4** (the tree's `vendor/` requires 8.4.1 or later) with the extensions Magento 2.4.8 needs (bcmath, ctype, curl, dom, gd, intl, mbstring, pdo_mysql, simplexml, soap, sockets, sodium, xsl, zip) and OPcache with `opcache.revalidate_path=0` and `realpath_cache_ttl` low enough that a relink is seen, as a real zero-downtime host sets it.
- **sshd** for one user, `deploy`, who owns `/var/www/magento`; key authentication only, no password, no root login. The key is the control container's.
- The three nodes are identical except their hostname and their `env.php`.

## The control container

The arms run here, as `zdt`: `docker compose --env-file lab.env exec -u zdt control bin/zdt-arm arm1 -n`. It mounts this repository read-only at `/playbook` and a writable run directory at `/runs`, which becomes `ZDT_RUN_DIR`. Its ssh key is generated at setup, and `known_hosts` is filled once by `ssh-keyscan` of the three nodes at setup, so the arms keep normal host-key checking. Its `~/.ssh/config` sets `User deploy` for the three nodes, so the arms name them plainly.

The arms' settings live in `lab.env` (gitignored; `lab.env.example` is committed with every value generic). **Every `docker compose` command here takes `--env-file lab.env`**, because Compose otherwise reads its variables from `.env`. The database passwords are Compose secrets read from `secrets/db_root_password`, `secrets/db_app_password` and `secrets/db_repl_password`, and the fleet's ssh key pair is `keys/id_ed25519`; both folders are gitignored and made at setup:

| Variable | Value in the lab |
|---|---|
| `ZDT_WEB_HOSTS` | `web1,web2,web3` |
| `ZDT_NEW_NODE`, `ZDT_ADMIN_NODE` | `web1` |
| `ZDT_LB_URL` | `http://lb` |
| `ZDT_NODE_URLS` | `http://web1,http://web2,http://web3` |
| `ZDT_ENV_PHP` | `/var/www/magento/shared/app/etc/env.php` |
| `ZDT_DB_HOST`, `ZDT_PRIMARY_HOST` | `db-primary` |
| `ZDT_REPLICA_HOST` | `db-replica` |
| `ZDT_CATEGORY_PATH`, `ZDT_PRODUCT_PATH` | a category and a product the fixtures created, read from the store after install |

## The store

- **Magento Open Source 2.4.8-p2**, from a tree that already has its `vendor/`, so nothing is fetched from a Composer repository. **The tree's `auth.json` is never copied**, into a release or anywhere else.
- **Production mode**: `setup:di:compile` and `setup:static-content:deploy en_US -f` are run once when a release is built, and baked into its tarball.
- Installed once, from `web1`, against `db-primary`: search on `opensearch`, cache, page cache and sessions on `valkey`, base URL `http://lb/`, `web/url/redirect_to_base` 0 so a request to a node by name is served rather than redirected, admin on an invented user.
- **Data**: `setup:performance:generate-fixtures` with the small profile, so categories and products exist without sample data or a download.
- **The replica** is seeded from the primary after the install and follows it by GTID from then on.

## The releases

Each release is a `tar.gz` of a whole Magento tree. **The builder makes it**: it mounts the source tree read-only at `/src` and the `releases` volume at `/releases`, copies the tree without `auth.json`, `app/etc/env.php`, `var/`, `generated/` and `pub/media/`, adds the release's module, compiles, deploys static content, and writes `/releases/<label>.tar.gz`. The control container mounts the same volume read-only, since that is where `ZDT_RELEASE_TARBALL` is read from.

**The source tree** is copied to the Docker host once, with the same exclusions. Its path is `ZDT_LAB_SRC` in `lab.env`, and this repository's checkout on that host is `ZDT_PLAYBOOK`; both are absolute, because nothing in this directory may reach outside it.

**Static content needs the store's websites and themes, and a build has no database.** So the first `r0` is built without static content and used only to install. `bin/install-store` then runs `app:config:dump scopes themes` and keeps that `config.php` in the `lab-config` volume, and every release after it, `r0` included, is built from it with its static content deployed. This is Magento's own way of building without a database.

| Label | What it adds | Used by |
|---|---|---|
| `r0` | The installed store. Deployed on all three nodes before any arm | every arm, as `ZDT_LABEL_OLD` |
| `r1` | A module, `Lab_ZdtProbe`, whose schema adds table `lab_zdt_probe` with a column `probe_value`, and a route `/zdtprobe/read` that reads it | arms 1 and 2, as `ZDT_LABEL_NEW` |
| `r2-additive` | `r1` plus a column `probe_extra`. Adds only | arm 3's control leg |
| `r2-breaking` | `r1` with `probe_value` renamed to `probe_value_v2`, and the route reading the new name | arm 3's evidence leg, arm 4 |

For arm 3, the old servers run `r1`. **`/zdtprobe/read` is `ZDT_READ_PATH` and `probe_value` is `ZDT_SCHEMA_OBJECT`.** When the column is gone, the route answers 500 and its body carries the database's own error message, which names the column. In production mode Magento would otherwise hide that behind a report number, and falsifier 3 needs the failure's own words.

## What counts as ready

The fleet is ready for the arms when every line below has been seen, not assumed:

1. `bin/zdt-fleet replica-check` passes from `control`: the replica is live, both threads running, lag 0.
2. All three nodes, and the load balancer, answer 200 on `/`, the category page, the product page, `/checkout/cart/`, `/rest/V1/directory/currency`, a GraphQL query and `/health_check.php`.
3. Every node runs `r0`, and each has its own `env.php`.
4. `bin/zdt-arm arm1 -n`, `arm2 -n`, `arm3 -n` and `arm4 -n` print a whole plan with no missing setting.
5. `docker stats` shows every container under its limit, and `docker ps` shows no port published except the load balancer's on `127.0.0.1`.

## Taking it down

```bash
docker compose --env-file lab.env --profile build down --volumes
```

That removes only what carries the `zdtfleet` project label.
