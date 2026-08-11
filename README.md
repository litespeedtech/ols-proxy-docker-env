# OpenLiteSpeed Docker Reverse Proxy

[![Build Status](https://github.com/litespeedtech/ols-proxy-docker-env/workflows/proxy-test/badge.svg)](https://github.com/litespeedtech/ols-proxy-docker-env/actions/)
[![docker pulls](https://img.shields.io/docker/pulls/litespeedtech/openlitespeed?style=flat&color=blue)](https://hub.docker.com/r/litespeedtech/openlitespeed)
[![LiteSpeed on Slack](https://img.shields.io/badge/slack-LiteSpeed-blue.svg?logo=slack)](https://litespeedtech.com/slack)
[![Follow on Twitter](https://img.shields.io/twitter/follow/litespeedtech.svg?label=Follow&style=social)](https://twitter.com/litespeedtech)

This project runs the official `litespeedtech/openlitespeed` image as a Dockerized OpenLiteSpeed reverse proxy. The primary `.env` domain uses the default `Example` virtual host, and optional additional domains use standalone virtual hosts instead of virtual-host templates.

The configuration includes:

- A per-VH OLS proxy External App (`proxy_backend`, `proxy_backend2`, and so on).
- Selectable RewriteRule or proxy-context routing to the backend.
- HTTP and HTTPS listeners on ports `80` and `443`, including UDP `443` for HTTP/3 QUIC.
- OpenLiteSpeed ACME certificate management (domain must point to this server).

## Configuration

Copy the example environment file and edit the values:

```sh
cp .env.example .env
```

```dotenv
OLS_IMAGE=litespeedtech/openlitespeed:latest
BACKEND_IP=192.168.0.1
BACKEND_PORT=1234
DOMAIN=www.example.com
ACME_EMAIL=
PROXY_SOCKET=false
PROXY_METHOD=rewrite
### HEADER_SET works with Context mode only ###
# HEADER_SET=RequestHeader set Origin "https://www.example.com"
```

`DOMAIN` is used for the OLS listener mapping and is sent to the backend as the `Host` header.

`BACKEND_IP` is the backend host, not necessarily a numeric IP address. It may be an IP address, DNS hostname, or Docker service/container name such as `backend-service` when both containers share a Docker network. Use the backend container port in that case; for example, `backend-service:8080`, not the host-published port from a `host-port:container-port` mapping.

Set `PROXY_SOCKET=true` to add an OpenLiteSpeed WebSocket proxy block. By default, it reuses `BACKEND_IP` and `BACKEND_PORT`, which is the usual setup when HTTP and WebSocket traffic belong to the same application. Set `PROXY_SOCKET_IP` and `PROXY_SOCKET_PORT` only when the WebSocket service uses a different backend.

`PROXY_METHOD=R` or `PROXY_METHOD=rewrite` uses the default RewriteRule proxy. `PROXY_METHOD=C` or `PROXY_METHOD=context` uses an OpenLiteSpeed proxy context. Values are case-insensitive.

Context mode optionally accepts one request-header directive through `HEADER_SET`, for example:

```dotenv
PROXY_METHOD=context
HEADER_SET=RequestHeader set Origin "https://www.example.com"
```

For safety, `HEADER_SET` must exactly match `RequestHeader set Header-Name "value"`. Newlines, backslashes, braces, extra quotes, unsupported characters, values longer than 1024 characters, and transport-sensitive headers such as `Host`, `Content-Length`, and `Transfer-Encoding` are rejected.

## Connect another Docker stack

Compose creates a shared bridge network named `ls-net`. Any backend container that should be reached by its Docker service or container name must join this network.

For a backend in another Compose project, add the external network to that project's `docker-compose.yml`:

```yaml
services:
  backend:
    networks:
      - ls-net

networks:
  ls-net:
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

## FAQ

### How to add additional domains

The `.env` configuration always defines the primary single-domain proxy and remains backward compatible. If additional domains are required, add one valid entry per line to `domains.conf`:

```text
DOMAIN, BACKEND_IP, BACKEND_PORT, PROXY_SOCKET, PROXY_METHOD, HEADER_SET
second.example.com, backend-service, 8080, false, context, RequestHeader set Origin "https://www.example.com"
```

The primary `.env` domain remains the `Example` virtual host. Each line in `domains.conf` creates an additional virtual host named from the domain, an independent proxy External App, an HTTP/HTTPS listener mapping, and its own ACME-enabled VHost configuration. The primary VHost uses `proxy_backend`; additional VHosts use `proxy_backend2`, `proxy_backend3`, and so on. Do not add `OLS_IMAGE` or `ACME_EMAIL` to `domains.conf`; those settings remain global in `.env`.

`PROXY_METHOD` and `HEADER_SET` are optional for backward compatibility: an existing four-field line defaults to RewriteRule mode. A five-field line selects the proxy method, and a six-field line may add one validated header in Context mode. Because fields are comma-separated, `HEADER_SET` cannot contain a comma.

`PROXY_SOCKET` must be exactly `true` or `false`. When it is `true`, the WebSocket backend uses the same host and port from that line. The parser rejects missing fields, invalid domains, invalid backend hosts, invalid ports, invalid Boolean values, invalid proxy methods or headers, duplicate domains, and extra comma-separated fields.

The file is mounted read-only into the container, so changing `domains.conf` does not require an image rebuild. Restart the proxy after changes:

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
