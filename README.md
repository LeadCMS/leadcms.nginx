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
- [Reloading Nginx configuration without downtime](#45a36b34f024f33bed82349e9096051a)
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
3. Cron triggers Certbot to try to renew certificates and Nginx to reload configuration daily

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
Switching Nginx to use Let's Encrypt certificate
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

## <a id="45a36b34f024f33bed82349e9096051a"></a>Reloading Nginx configuration without downtime

Do a hot reload of the Nginx configuration:

```bash
docker compose exec --no-TTY nginx nginx -s reload
```

## <a id="adding-a-new-domain"></a>Adding a new domain to a running stack

Adding a domain requires two containers to be updated: **nginx** (to render the new vhost config) and **certbot** (to issue the TLS certificate).

Certbot is a **one-shot container** — it runs once at stack startup, issues certificates for every domain that doesn't have one yet, then exits with code 0. It does not stay running. When you restart only nginx, certbot remains in its exited state and never fires for the new domain, so nginx loops on "Waiting for Let's Encrypt certificates" indefinitely.

The correct procedure when adding a new domain:

**1. Edit `config.env`** — add the new `DOMAIN_N`, `DOMAINTARGET_N`, `CERTBOTEMAIL_N` entries.

**2. Rebuild nginx and restart certbot:**

```bash
docker compose up -d --build nginx && docker compose up certbot
```

- `docker compose up -d --build nginx` — rebuilds the nginx image with the new templates and recreates the container. Nginx generates a dummy TLS certificate for the new domain and starts waiting for the real one.
- `docker compose up certbot` — creates a fresh certbot container (the old one was exited). The script skips all domains that already have a certificate and only issues new ones.

Alternatively, `docker compose up -d --build` (without specifying a service) also works — it rebuilds all images and starts a fresh certbot container because the old one was exited.

**3. Watch the logs** to confirm the certificate is issued:

```bash
docker compose logs -f certbot nginx
```

You should see `Switching Nginx to use Let's Encrypt certificate for <domain>` within a minute or two.

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

GitHub Actions runs the same suite with [nginx-integration.yml](.github/workflows/nginx-integration.yml).
