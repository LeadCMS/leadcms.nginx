# Nginx and Let’s Encrypt with Docker Compose in less than 3 minutes

- [Overview](#3b878279a04dc47d60932cb294d96259)
- [Initial setup](#1231369e1218613623e1b520c27ce190)
  - [Prerequisites](#ee68e5b99222bbc29a480fcb0d1d6ee2)
  - [Step 0 - Create DNS records](#288c0835566de0a785d19451eac904a0)
  - [Step 1 - Edit domain names and emails in the configuration](#f24b6b41d1afb4cf65b765cf05a44ac1)
  - [Step 2 - Configure Nginx virtual hosts](#3414177b596079dbf39b1b7fa10234c6)
    - [Serving static content](#cdbe8e85146b30abdbb3425163a3b7a2)
    - [Proxying all requests to a backend server](#c156f4dfc046a4229590da3484f9478d)
  - [Step 3 - Create named Docker volumes for dummy and Let's Encrypt TLS certificates](#b56e2fee036d09a35898559d9889bae7)
  - [Step 4 - Build images and start containers using staging Let's Encrypt server](#4952d0670f6fb00a0337d2251621508a)
  - [Step 5 - verify HTTPS works with the staging certificates](#46d3804a4859874ba8b6ced6013b9966)
  - [Step 6 - Switch to production Let's Encrypt server](#04529d361bbd6586ebcf267da5f0dfd7)
  - [Step 7 - verify HTTPS works with the production certificates](#70d8ba04ba9117ff3ba72a9413131351)
- [Applying configuration changes without downtime](#45a36b34f024f33bed82349e9096051a)
- [Adding a new domain to a running stack](#adding-a-new-domain)
- [HTTP Basic Authentication](#http-basic-auth)

<!-- Table of contents is made with https://github.com/evgeniy-khist/markdown-toc -->

## <a id="3b878279a04dc47d60932cb294d96259"></a>Overview

This example automatically obtains and renews [Let's Encrypt](https://letsencrypt.org/) TLS certificates and sets up HTTPS in Nginx for multiple domain names using Docker Compose.

You can set up HTTPS in Nginx with Let's Encrypt TLS certificates for your domain names and get an A+ rating in [SSL Labs SSL Server Test](https://www.ssllabs.com/ssltest/) by changing a few configuration parameters of this example.

Let's Encrypt is a certificate authority that provides free X.509 certificates for TLS encryption.
The certificates are valid for 90 days and can be renewed. Both initial creation and renewal can be automated using [Certbot](https://certbot.eff.org/).

When using Kubernetes Let's Encrypt TLS certificates can be easily obtained and installed using [Cert Manager](https://cert-manager.io/).
For simple websites and applications, Kubernetes is too much overhead and Docker Compose is more suitable.
But for Docker Compose there is no such popular and robust tool for TLS certificate management.

The example supports separate TLS certificates for multiple domain names, e.g. `example.com`, `anotherdomain.net` etc.
For simplicity this example deals with the following domain names:

- `cms.leadcms.ai`
- `leadcms.ai`

The idea is simple. There are 3 containers:

- **Nginx**
- **Certbot** - for obtaining and renewing certificates
- **Cron** - for triggering certificates renewal once a day

The sequence of actions:

1. Nginx generates self-signed "dummy" certificates to pass ACME challenge for obtaining Let's Encrypt certificates
2. Certbot waits for Nginx to become ready and obtains certificates
3. Nginx swaps each domain over to its real certificate as soon as it is issued
4. Cron triggers Certbot to try to renew certificates and Nginx to reload configuration daily

Once the stack is up, `config.env` changes are applied with [`./apply-config.sh`](#45a36b34f024f33bed82349e9096051a) — no restart and no dropped connections. See [Applying configuration changes without downtime](#45a36b34f024f33bed82349e9096051a).

## <a id="1231369e1218613623e1b520c27ce190"></a>Initial setup

### <a id="ee68e5b99222bbc29a480fcb0d1d6ee2"></a>Prerequisites

1. [Docker](https://docs.docker.com/install/) and [Docker Compose](https://docs.docker.com/compose/install/) are installed
2. You have a domain name
3. You have a server with a publicly routable IP address
4. You have cloned this repository (or created and cloned a [fork](https://github.com/peterliapin/leadcms-nginx/fork)):
   ```bash
   git clone https://github.com/LeadCMS/leadcms.nginx.git
   ```

### <a id="288c0835566de0a785d19451eac904a0"></a>Step 0 - Create DNS records

For all domain names create DNS A records to point to a server where Docker containers will be running.

**DNS records**

| Type | Hostname         | Value                           |
| ---- | ---------------- | ------------------------------- |
| A    | `cms.leadcms.ai` | directs to IP address `X.X.X.X` |
| A    | `leadcms.ai`     | directs to IP address `X.X.X.X` |

### <a id="f24b6b41d1afb4cf65b765cf05a44ac1"></a>Step 1 - Edit domain names and emails in the configuration

Copy the contents of config.env.sample to config.env and specify your domain names, contact emails and targets for these domains with space as delimiter in the [`config.env`](config.env):

```bash
DOMAINS="cms.leadcms.ai leadcms.ai"
TARGETS="http://cms_leadcms_ai:80 /var/www/html/leadcms.ai"
CERTBOT_EMAILS="support@leadcms.ai support@leadcms.ai"
```

For two and more domains separated by space use double quotes (`"`) around the `DOMAINS` and `CERTBOT_EMAILS` variables.

For a single domain double quotes can be omitted:

```bash
DOMAINS=cms.leadcms.ai
TARGETS=http://cms_leadcms_ai:80
CERTBOT_EMAILS=support@leadcms.ai
```

### <a id="3414177b596079dbf39b1b7fa10234c6"></a>Step 2 - Configure targets

For each domain you need to configure a target value to redirect incoming traffic to a service which runs on a local port inside a host PC, remote host or as a docker compose service inside the same docker network:

- `http://cms_leadcms_ai:80` - means all traffic will be redirected to the cms_leadcms_ai docker compose service (port 80) which is deployed in the same docker compose network
- `http://localhost:80` - means all traffic will be redirected to a local service running on port 80 on the a host PC
- `http://localhost:80` - means all traffic will be redirected to a local service running on port 80 on the a host PC
- `/var/www/html/leadcms.ai` - means that nginx will serve static content from /var/www/html/leadcms.ai folder which should be mounted to the nginx service using an external volume

#### <a id="cdbe8e85146b30abdbb3425163a3b7a2"></a>Serving static content

When you specify local path as a target, make sure `html/my-domain` directory (relative to the repository root) exists and countains the desired content and `html` directory is mounted as `/var/www/html` in `docker-compose.yml`:

```yaml
services:
  nginx:
  #...
  volumes:
    #...
    - ./html:/var/www/html
```

#### <a id="c156f4dfc046a4229590da3484f9478d"></a>Proxying all requests to a backend server

When you specify a docker compose service or local or remote service like http://my-backend:8080/ as a target, the nginx will automatically configure itselves using the following configuration template:

```
location / {
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_pass http://my-backend:8080/;
}
```

`my-backend` is the service name of your backend application in `docker-compose.yml`:

```yaml
services:
  my-backend:
    image: example.com/my-backend:1.0.0
    #...
    ports:
      - "8080"
```

### <a id="b56e2fee036d09a35898559d9889bae7"></a>Step 3 - Create named Docker volumes for dummy and Let's Encrypt TLS certificates, cert bot acme challanges, logs and static sites:

```bash
docker volume create --name=nginx_conf
docker volume create --name=nginx_ssl
docker volume create --name=letsencrypt_certs
docker volume create --name=certbot_acme_challenge
docker volume create --name=letsencrypt_logs
docker volume create --name=static_sites
```

### <a id="4952d0670f6fb00a0337d2251621508a"></a>Step 4 - Build images and start containers using staging Let's Encrypt server

```bash
docker compose up -d --build
docker compose logs -f
```

You can alternatively use the `docker-compose` binary.

For each domain wait for the following log messages:

```
Let's Encrypt certificates changed; re-rendering and reloading
Reloading Nginx configuration
```

### <a id="46d3804a4859874ba8b6ced6013b9966"></a>Step 5 - verify HTTPS works with the staging certificates

For each domain open in browser `https://${domain}` and verify that staging Let's Encrypt certificates are working:

- https://cms.leadcms.ai
- https://leadcms.ai

Certificates issued by `(STAGING) Let's Encrypt` are considered not secure by browsers.

### <a id="04529d361bbd6586ebcf267da5f0dfd7"></a>Step 6 - Switch to production Let's Encrypt server

Stop the containers:

```bash
docker compose down
```

Configure to use production Let's Encrypt server in [`config.env`](config.env):

```properties
CERTBOT_TEST_CERT=0
```

Re-create the volume for Let's Encrypt certificates:

```bash
docker volume rm letsencrypt_certs
docker volume create --name=letsencrypt_certs
```

Start the containers:

```bash
docker compose up -d
docker compose logs -f
```

### <a id="70d8ba04ba9117ff3ba72a9413131351"></a>Step 7 - verify HTTPS works with the production certificates

For each domain open in browser `https://${domain}` and `https://www.${domain}` and verify that production Let's Encrypt certificates are working.

Certificates issued by `Let's Encrypt` are considered secure by browsers.

Optionally check your domains with [SSL Labs SSL Server Test](https://www.ssllabs.com/ssltest/) and review the SSL Reports.

## <a id="45a36b34f024f33bed82349e9096051a"></a>Applying configuration changes without downtime

`config.env` reaches Nginx two ways: Compose reads it as `env_file` when the container is **created**, and the project directory is bind-mounted read-only at `/etc/nginx/hostconfig` so a **running** container can re-read it at any time. That second path is what makes a restart unnecessary.

After editing [`config.env`](config.env) — adding a domain, changing a target, raising the upload limit — apply it with:

```bash
./apply-config.sh
```

That does three things, in this order:

1. re-renders every virtual host inside the running Nginx container and hot-reloads with `nginx -s reload`, which starts new workers and lets the old ones finish their in-flight requests — **no connection is dropped and no other domain is interrupted**;
2. runs Certbot for the domains that have no certificate yet, skipping every domain that already has one;
3. reloads once more so a freshly issued certificate replaces the self-signed placeholder.

A new domain is serving traffic a couple of seconds in (on the placeholder certificate) and has a real certificate about a minute later. Adding one domain costs one certificate request, not one per configured domain.

### Options

| Command                                   | Effect                                                                         |
| ----------------------------------------- | ------------------------------------------------------------------------------ |
| `./apply-config.sh`                       | Render, hot reload, then issue any missing certificates                        |
| `./apply-config.sh --dry-run`             | Print exactly which vhosts would be added, removed or changed. Applies nothing |
| `./apply-config.sh --no-certs`            | Configuration only — skip Certbot entirely                                     |
| `./apply-config.sh --domains a.com,b.com` | Limit certificate issuance to these domains                                    |

On a busy stack it is worth running `--dry-run` first:

```
==> Pending configuration changes (project=leadcmsnginx)
Dry run — nothing was applied. Pending changes:
  + new.example.com.conf
  + maps/new.example.com.conf
  2 added, 0 removed, 0 changed
```

### Why this is safe

The rendered files are snapshotted before every apply. If `nginx -t` rejects the result, the previous files are restored and the script exits non-zero — and since the reload never happened, Nginx is still serving the configuration it already had. A typo in `config.env` cannot take the stack down.

Certbot pre-flights each domain before asking Let's Encrypt to validate it: it writes a token under the domain's ACME webroot and fetches it back through Nginx. A domain that is not being served yet is skipped with an explanation, rather than consuming one of Let's Encrypt's [five failed validations per hostname per hour](https://letsencrypt.org/docs/rate-limits/).

### Removing a domain

Delete its `DOMAIN_N` block from `config.env` and run `./apply-config.sh`. The virtual host and its redirect maps are pruned on the next reload. The issued certificate is left under `/etc/letsencrypt` in case the domain comes back.

### What still needs a restart

Only changes to the stack itself, never to `config.env`:

- published ports, volumes or services in `docker-compose.yml`
- the Nginx templates or any `Dockerfile` — `docker compose up -d --build`

### Reloading by hand

`apply-config.sh` is a wrapper around scripts inside the container, which can be called directly:

```bash
docker compose exec -T nginx /customization/render.sh --dry-run  # show pending changes
docker compose exec -T nginx /customization/reload.sh            # re-render, validate, reload
```

A bare `nginx -s reload` still works, but it does not re-render, so it will **not** pick up `config.env` changes:

```bash
docker compose exec --no-TTY nginx nginx -s reload
```

## <a id="adding-a-new-domain"></a>Adding a new domain to a running stack

**1. Create the DNS record** for the new domain pointing at the server, and wait for it to resolve — Certbot warns when it does not.

**2. Add the domain to [`config.env`](config.env):**

```properties
DOMAIN_4="new.example.com"
DOMAINTARGET_4="http://new_example_com"
CERTBOTEMAIL_4="support@example.com"
```

**3. Apply it:**

```bash
./apply-config.sh --dry-run   # confirm only the new virtual host appears
./apply-config.sh
```

The run ends with a per-domain summary:

```
==> Issuing certificates for domains that do not have one
Certificate summary:
  issued   new.example.com
  skipped  cms.example.com (already has a certificate)
==> Reloading nginx to pick up any newly issued certificate
==> Done
```

If issuance fails — DNS not propagated, port 80 blocked — the script says so and exits non-zero. The new domain stays live on its placeholder certificate, every other domain is untouched, and you can retry just that one:

```bash
./apply-config.sh --domains new.example.com
```

> **Upgrading an existing deployment.** Hot reload needs the `/etc/nginx/hostconfig` mount and the new container scripts, so adopt it with one last full restart — `docker compose up -d --build`. Every `config.env` change after that is hot. If `apply-config.sh` reports that `config.env` cannot be found inside the container, this step was skipped.

## <a id="http-basic-auth"></a>HTTP Basic Authentication

You can protect any domain or sub-location with HTTP Basic Auth without rebuilding the container. Credentials are stored in [htpasswd](https://httpd.apache.org/docs/current/programs/htpasswd.html) files that are bind-mounted read-only into Nginx.

> **Important:** Basic Auth only makes sense over HTTPS. The setup here uses TLS by default, so credentials are always encrypted in transit.

### Step 1 — Create a password file

Password files live in the `htpasswd/` directory at the repository root. The directory is mounted into the container as `/etc/nginx/htpasswd/`.

Create a file for the domain you want to protect (the filename is arbitrary — you reference it in `config.env`):

```bash
# Install htpasswd if needed: sudo apt install apache2-utils
htpasswd -c ./htpasswd/cms.example.com admin
# enter password when prompted
```

To add more users to an existing file (omit `-c` to avoid overwriting):

```bash
htpasswd ./htpasswd/cms.example.com another_user
```

To remove a user:

```bash
htpasswd -D ./htpasswd/cms.example.com username
```

Password file changes take effect after reloading Nginx — no container restart needed:

```bash
docker compose exec --no-TTY nginx nginx -s reload
```

### Step 2 — Protect a whole domain

Set `DOMAIN_N_AUTH=1` for the domain you want to protect in `config.env`:

```env
DOMAIN_1="cms.example.com"
DOMAINTARGET_1="http://cms_backend"
CERTBOTEMAIL_1="admin@example.com"
DOMAIN_1_AUTH=1
DOMAIN_1_AUTH_FILE=cms.example.com   # filename inside ./htpasswd/ — defaults to domain name if omitted
```

All paths on `cms.example.com` will now require a login. The `DOMAIN_1_AUTH_FILE` value matches the filename you created in Step 1. If omitted, it defaults to the domain name itself.

You can also customise the browser dialog title (optional):

```env
DOMAIN_1_AUTH_REALM="My Private Site"
```

### Step 3 — Protect only a sub-location

Leave `DOMAIN_N_AUTH` unset and enable auth only on the specific location instead:

```env
DOMAIN_1="cms.example.com"
DOMAINTARGET_1="http://cms_backend"
CERTBOTEMAIL_1="admin@example.com"
DOMAIN_1_LOCATION_1="admin"
DOMAIN_1_LOCATION_1_TARGET="http://admin_backend"
DOMAIN_1_LOCATION_1_AUTH=1
DOMAIN_1_LOCATION_1_AUTH_FILE=cms.example.com   # optional, defaults to domain name
```

Now `/admin/` is password-protected while the rest of `cms.example.com` is publicly accessible.

### Quick reference

| Variable                         | Scope           | Required        | Default           |
| -------------------------------- | --------------- | --------------- | ----------------- |
| `DOMAIN_N_AUTH`                  | whole domain    | yes (to enable) | —                 |
| `DOMAIN_N_AUTH_REALM`            | whole domain    | no              | `Restricted Area` |
| `DOMAIN_N_AUTH_FILE`             | whole domain    | no              | domain name       |
| `DOMAIN_N_LOCATION_M_AUTH`       | single location | yes (to enable) | —                 |
| `DOMAIN_N_LOCATION_M_AUTH_REALM` | single location | no              | `Restricted Area` |
| `DOMAIN_N_LOCATION_M_AUTH_FILE`  | single location | no              | domain name       |

## CI integration testing

The repository includes a separate integration test stack that exercises the rendered Nginx configuration against static fixtures and a mock backend.

Run it locally with:

```bash
bash test/run-integration-tests.sh
```

The test suite builds Nginx, starts a mock backend, renders all configured vhosts from [`config.env.test`](config.env.test), and verifies:

- plain static hosting and custom 404 handling
- static location aliases
- Gatsby and NextJS cache-control behavior
- redirect hosts
- proxied service hosts
- generated SSE and WSS routes
- HTTP Basic Auth on a whole domain and on a single location
- hot reload: adding, removing and reconfiguring a domain against a running Nginx, dry runs, certificate promotion, Certbot's pre-flight, and rollback of a configuration Nginx rejects

GitHub Actions runs the same suite with [nginx-integration.yml](.github/workflows/nginx-integration.yml).

### Running a single case

```bash
bash test/run-integration-tests.sh --list                       # case names
bash test/run-integration-tests.sh --only "hot reload adds a domain"
```

`--reuse` attaches to a stack that is already running instead of rebuilding it, and `--keep` leaves it running afterwards, which turns a single case into a two-second run. The runner rebuilds on its own whenever anything under `nginx/` or `certbot/` changed since the last build, so a reused stack never serves stale container scripts. Stop the stack with `--teardown`.

### Running from the VS Code test explorer

[`test/test_integration.py`](test/test_integration.py) exposes every case as its own node in the test explorer, so cases can be run and re-run individually from the editor. It is a thin wrapper — the suite itself stays in bash and CI runs it directly, with no Python involved.

The workspace is already configured in [.vscode/settings.json](.vscode/settings.json); all it needs is pytest in the interpreter VS Code has selected:

```bash
python3 -m pip install -r test/requirements-dev.txt
```

Then open the Testing view and hit refresh. Two tasks are also available from _Run Task_: **Integration tests: full suite** (rebuild and run everything in one docker session, as CI does) and **Integration tests: tear down stack**.

> The stack is deliberately left running between test explorer runs so a re-run takes seconds. Tear it down with the task above, or `bash test/run-integration-tests.sh --teardown`.
