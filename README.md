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
