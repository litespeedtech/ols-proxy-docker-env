# OpenLiteSpeed Docker Reverse Proxy

[![Build Status](https://github.com/litespeedtech/ols-proxy-docker-env/workflows/proxy-test/badge.svg)](https://github.com/litespeedtech/ols-proxy-docker-env/actions/)
[![docker pulls](https://img.shields.io/docker/pulls/litespeedtech/openlitespeed?style=flat&color=blue)](https://hub.docker.com/r/litespeedtech/openlitespeed)
[![LiteSpeed on Slack](https://img.shields.io/badge/slack-LiteSpeed-blue.svg?logo=slack)](https://litespeedtech.com/slack)
[![Follow on Twitter](https://img.shields.io/twitter/follow/litespeedtech.svg?label=Follow&style=social)](https://twitter.com/litespeedtech)

This project runs the official `litespeedtech/openlitespeed` image as a Dockerized OpenLiteSpeed reverse proxy. The primary `.env` domain uses the default `Example` virtual host, and optional additional domains use standalone virtual hosts instead of virtual-host templates.

The configuration includes:

- A per-VH OLS proxy External App
- Selectable RewriteRule or proxy-context routing to the backend.
- HTTP and HTTPS listeners on ports `80` and `443`, including UDP `443` for HTTP/3 QUIC.
- OpenLiteSpeed ACME certificate management (domain must point to this server).

## Configuration

Clone the project and enter its directory:

```sh
git clone https://github.com/litespeedtech/ols-proxy-docker-env.git
cd ols-proxy-docker-env
```

Copy the environment file and edit the values:

```sh
cp .env.example .env
```

```dotenv
OLS_IMAGE=litespeedtech/openlitespeed:latest
BACKEND_IP=192.168.0.1
BACKEND_PORT=1234
DOMAIN=www.example.com
ACME_EMAIL=
PROXY_METHOD=context
PROXY_SOCKET=false
HEADER_SET=
```

`DOMAIN` is used for the OLS listener mapping and is sent to the backend as the `Host` header.

`BACKEND_IP` is the backend host, not necessarily a numeric IP address. It may be an IP address, DNS hostname, or Docker service/container name such as `backend-service` when both containers share a Docker network. 
Use the backend container port in that case; for example, `backend-service:8080`, not the host-published port from a `host-port:container-port` mapping.

Set `PROXY_SOCKET=true` to add an OpenLiteSpeed WebSocket proxy block. By default, it reuses `BACKEND_IP` and `BACKEND_PORT`, which is the usual setup when HTTP and WebSocket traffic belong to the same application. Set `PROXY_SOCKET_IP` and `PROXY_SOCKET_PORT` only when the WebSocket service uses a different backend.

`PROXY_METHOD=context` uses an OpenLiteSpeed proxy context.
`PROXY_METHOD=rewrite` uses the default RewriteRule proxy. 

Context mode optionally accepts one OLS header operation through `HEADER_SET`, for example:

```dotenv
PROXY_METHOD=context
HEADER_SET=X-XSS-Protection 1;mode=block
```

Supported syntax:

```text
<Header|RequestHeader> <set|append|merge|add|unset> <header-name> ["value"]
```

For a response header, `Header set` may be omitted. For example, `X-XSS-Protection 1;mode=block` is treated as `Header set X-XSS-Protection 1;mode=block`. A colon after the header name is optional. 

## Connect another Docker stack

Compose creates a shared bridge network named `ls-net`. Any backend container that should be reached by its Docker service or container name must join this network.

For a backend in another Compose project, add the external network to that project's `docker-compose.yml`:

```yaml
networks:
  default:
    name: ls-net
    external: true
```

Then use the backend service name and its internal container port in `.env`:

```dotenv
BACKEND_IP=backend
BACKEND_PORT=8080
```

For a container started with `docker run`, attach it to the shared network:

```sh
docker network connect ls-net <backend-container-name>
```

Use the container's internal listening port, not a host port mapping. For example, a `3000:8080` mapping is reached from OLS as `backend:8080` when both containers use `ls-net`.

## Start command

Start the proxy:

```sh
docker compose up -d
```

The first startup builds the local image automatically. It may also pull the selected OpenLiteSpeed base image.

View status and logs:

```sh
docker compose ps
docker compose logs -f ols-proxy
```

Changing `.env` requires restarting the container:

```sh
docker compose down
docker compose up -d
```

Changing `domains.conf` only requires restarting the container. Changing `Dockerfile` or `docker-entrypoint.sh` requires rebuilding:

```sh
docker compose up -d --build
```

## Global security controls

Security controls are global by design and apply to every domain, including domains added through `domains.conf`. They are configured only in `.env` and are never read from `domains.conf`.

After changing `.env`, recreate the proxy with `docker compose down` followed by `docker compose up -d`.

`THROTTLING=true` enables OpenLiteSpeed per-client limits using the `THROTTLING_*` values in `.env`.

`RECAPTCHA=true` enables OpenLiteSpeed CAPTCHA when either configured concurrent-connection limit in `.env` is reached. `RECAPTCHA_SITE_KEY` and `RECAPTCHA_SECRET_KEY` are optional; when blank, they are omitted from the generated OLS configuration.

`MODSECURITY=true` enables the OpenLiteSpeed ModSecurity engine and OWASP Core Rule Set (CRS). The CRS version is selected only at build time through `OWASP_CRS_VERSION` (default `4.21.0`). Changing it requires rebuilding with the desired `.env` value, for example `docker compose up -d --build`.

## Application Examples

The OpenLiteSpeed Docker Proxy supports a wide range of Docker-based applications. The following are some examples with application-specific configuration guides:

| Application | Documentation |
| --- | --- |
| **n8n** | [n8n + OpenLiteSpeed](https://docs.openlitespeed.org/apps/n8n/) |
| **Uptime Kuma** | [Uptime Kuma + OpenLiteSpeed](https://docs.openlitespeed.org/apps/uptimekuma/) |
| **AnythingLLM** | [AnythingLLM + OpenLiteSpeed](https://docs.openlitespeed.org/apps/anythingllm/) |
| **LibreChat** | [LibreChat + OpenLiteSpeed](https://docs.openlitespeed.org/apps/librechat/) |
| **Open WebUI** | [Open WebUI + OpenLiteSpeed](https://docs.openlitespeed.org/apps/openwebui/) |
| **Langflow** | [Langflow + OpenLiteSpeed](https://docs.openlitespeed.org/apps/langflow/) |

## FAQ

### How to add additional domains

Keep the primary domain in `.env`. Add each additional domain on a new line in `domains.conf`.

Context method example:

```text
DOMAIN, BACKEND_IP, BACKEND_PORT, PROXY_SOCKET, PROXY_METHOD, HEADER_SET
second.example.com, backend-service, 8080, false, context, Strict-Transport-Security: max-age=31536000; includeSubDomains
```

Rewrite method example:

```text
third.example.com, another-backend, 3000, false, rewrite
```

Use `PROXY_SOCKET=true` only when the backend needs WebSocket support. `HEADER_SET` is optional and works only with the `context` method. With `rewrite`, it is ignored and a warning is written to the container log.

Restart the proxy after editing the file:

```sh
docker compose restart ols-proxy
```

### How to visit WebAdmin

WebAdmin port `7080` is disabled by default. If needed, uncomment `- "7080:7080"` under `ports`, then recreate the container:

```sh
docker compose up -d
```

Set or reset the WebAdmin password interactively:

```sh
docker compose exec ols-proxy /usr/local/lsws/admin/misc/admpass.sh
```


## Support & Feedback

If you still have a question after using OpenLiteSpeed Docker, you have a few options.

* Join [the GoLiteSpeed Slack community](https://litespeedtech.com/slack) for real-time discussion
* Post to [the OpenLiteSpeed Forums](https://forum.openlitespeed.org/) for community support
* Reporting any issue on [Github ols-proxy-docker-env](https://github.com/litespeedtech/ols-proxy-docker-env/issues) project

**_Pull requests are always welcome!_**
