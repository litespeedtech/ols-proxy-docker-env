# OpenLiteSpeed Docker Reverse Proxy

[![Build Status](https://github.com/litespeedtech/ols-proxy-docker-env/workflows/proxy-test/badge.svg)](https://github.com/litespeedtech/ols-proxy-docker-env/actions/)
[![Docker pulls](https://img.shields.io/docker/pulls/litespeedtech/openlitespeed?style=flat&color=blue)](https://hub.docker.com/r/litespeedtech/openlitespeed)
[![LiteSpeed on Slack](https://img.shields.io/badge/slack-LiteSpeed-blue.svg?logo=slack)](https://litespeedtech.com/slack)
[![Follow on Twitter](https://img.shields.io/twitter/follow/litespeedtech.svg?label=Follow&style=social)](https://twitter.com/litespeedtech)

This project runs the official `litespeedtech/openlitespeed` image as a Dockerized OpenLiteSpeed reverse proxy. The `DOMAIN` value in `.env` uses the default `Example` virtual host, while optional additional domains use standalone virtual hosts instead of virtual-host templates.

The configuration includes:

- A per-VH OLS proxy External App.
- Selectable `RewriteRule` or proxy-context routing to the backend.
- HTTP and HTTPS listeners on ports `80` and `443`, including UDP `443` for HTTP/3 QUIC.
- OpenLiteSpeed ACME certificate management; the domain must point to this server.

## Configuration

1. Clone the project and enter its directory:

    ```sh
    git clone https://github.com/litespeedtech/ols-proxy-docker-env.git
    cd ols-proxy-docker-env
    ```

2. Copy the environment file:

    ```sh
    cp .env.example .env
    ```

3. Edit `.env` with the required values:

    ```dotenv
    OLS_IMAGE=litespeedtech/openlitespeed:latest
    BACKEND_IP=192.0.2.1
    BACKEND_PORT=1234
    DOMAIN=www.example.com
    ACME_EMAIL=
    PROXY_METHOD=context
    PROXY_SOCKET=false
    HEADER_SET=
    ```

`DOMAIN` is used for the OLS listener mapping and is sent to the backend as the `Host` header.

`BACKEND_IP` is the backend host and does not have to be a numeric IP address. It can be an IP address, DNS hostname, or Docker service or container name, such as `backend-service`, when both containers share a Docker network. In this case, use the backend container port, such as `backend-service:8080`, rather than the host-published port from a `host-port:container-port` mapping.

Set `PROXY_SOCKET=true` to add an OpenLiteSpeed WebSocket proxy block. By default, it reuses `BACKEND_IP` and `BACKEND_PORT`, which is the usual setup when HTTP and WebSocket traffic belong to the same application. Set `PROXY_SOCKET_IP` and `PROXY_SOCKET_PORT` only when the WebSocket service uses a different backend.

`PROXY_METHOD=context` uses an OpenLiteSpeed proxy context. `PROXY_METHOD=rewrite` uses the default `RewriteRule` proxy.

<details>
  <summary>Header Set</summary>

  Context mode optionally accepts one OLS header operation through `HEADER_SET`, for example:

  ```dotenv
  PROXY_METHOD=context
  HEADER_SET=X-XSS-Protection 1;mode=block
  ```

  Supported syntax:

  ```text
  <Header|RequestHeader> <set|append|merge|add|unset> <header-name> ["value"]
  ```

</details>


## Docker network setup

The proxy and backend applications use a shared **external Docker network** named `ls-net`.

Create the network before starting the proxy or any application that uses it:

```sh
docker network inspect ls-net >/dev/null 2>&1 || docker network create ls-net
```

This command creates `ls-net` only if it does not already exist.

## Connect another Docker stack

1. For a backend in another Compose project, add the external network to that project's `docker-compose.yml`:

    ```yaml
    networks:
      default:
        name: ls-net
        external: true
    ```

2. Use the backend service name and its internal container port in `.env`:

    ```dotenv
    BACKEND_IP=backend
    BACKEND_PORT=8080
    ```

### Docker Run
    For a container started with `docker run`, attach it to the shared network:

    ```sh
    docker network connect ls-net <backend-container-name>
    ```

Use the container's internal listening port, not a host port mapping. For example, a `3000:8080` mapping is reached from OLS as `backend:8080` when both containers use `ls-net`.

## Start command

1. Start the proxy:

    ```sh
    docker compose up -d
    ```

   The first startup builds the local image automatically. It may also pull the selected OpenLiteSpeed base image.

2. View status and logs:

    ```sh
    docker compose ps
    docker compose logs -f ols-proxy
    ```

3. Restart the container after changing `.env`:

    ```sh
    docker compose down
    docker compose up -d
    ```

4. Restart the container after changing `domains.conf`. Rebuild the container after changing `Dockerfile` or `docker-entrypoint.sh`:

    ```sh
    docker compose up -d --build
    ```

## Global security controls

Security controls are global by design and apply to every domain, including domains added through `domains.conf`. They are configured only in `.env` and are never read from `domains.conf`.

After changing `.env`, recreate the proxy.

<details>
  <summary>Per-client throttling</summary>

  `THROTTLING=true` enables OpenLiteSpeed per-client limits using the `THROTTLING_*` values in `.env`.

  Default values:

  ```dotenv
  THROTTLING=false
  THROTTLING_STATIC_REQ_PER_SEC=1000
  THROTTLING_DYNAMIC_REQ_PER_SEC=50
  THROTTLING_OUT_BANDWIDTH=0
  THROTTLING_IN_BANDWIDTH=0
  THROTTLING_SOFT_LIMIT=50
  THROTTLING_HARD_LIMIT=100
  THROTTLING_BLOCK_BAD_REQUEST=true
  THROTTLING_GRACE_PERIOD=15
  THROTTLING_BAN_PERIOD=60
  ```

</details>

<details>
  <summary>reCAPTCHA</summary>

  `RECAPTCHA=true` enables OpenLiteSpeed CAPTCHA when either of the configured concurrent-connection limits in `.env` is reached. `RECAPTCHA_SITE_KEY` and `RECAPTCHA_SECRET_KEY` are optional.

  Default values:

  ```dotenv
  RECAPTCHA=false
  RECAPTCHA_TYPE=checkbox
  RECAPTCHA_SITE_KEY=
  RECAPTCHA_SECRET_KEY=
  RECAPTCHA_MAX_TRIES=10
  RECAPTCHA_ALLOWED_ROBOT_HITS=100
  RECAPTCHA_CONNECTION_LIMIT=100
  RECAPTCHA_SSL_CONNECTION_LIMIT=100
  ```

</details>

<details>
  <summary>OWASP</summary>

  `MODSECURITY=true` enables the OpenLiteSpeed ModSecurity engine and OWASP Core Rule Set (CRS). The CRS version is selected only at build time through `OWASP_CRS_VERSION`. Changing it requires rebuilding with the desired `.env` value:

  ```sh
  docker compose up -d --build
  ```

  Default values:

  ```dotenv
  MODSECURITY=false
  OWASP_CRS_VERSION=4.21.0
  ```

</details>

## Application examples

The OpenLiteSpeed Docker Proxy supports a wide range of Docker-based applications. The following are examples with application-specific configuration guides:

| Application | Documentation |
| --- | --- |
| **n8n** | [n8n + OpenLiteSpeed](https://docs.openlitespeed.org/apps/n8n/) |
| **Uptime Kuma** | [Uptime Kuma + OpenLiteSpeed](https://docs.openlitespeed.org/apps/uptimekuma/) |
| **AnythingLLM** | [AnythingLLM + OpenLiteSpeed](https://docs.openlitespeed.org/apps/anythingllm/) |
| **LibreChat** | [LibreChat + OpenLiteSpeed](https://docs.openlitespeed.org/apps/librechat/) |
| **Open WebUI** | [Open WebUI + OpenLiteSpeed](https://docs.openlitespeed.org/apps/openwebui/) |
| **Langflow** | [Langflow + OpenLiteSpeed](https://docs.openlitespeed.org/apps/langflow/) |

## FAQ

### How do I add additional domains?

1. Keep the primary domain in `.env`.
2. Add each additional domain on a new line in `domains.conf`.

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

3. Restart the proxy after editing the file:

    ```sh
    docker compose restart ols-proxy
    ```

### How do I access the WebAdmin Console?

1. The WebAdmin Console port `7080` is disabled by default. Uncomment `- "7080:7080"` under `ports`, then recreate the container:

    ```sh
    docker compose up -d
    ```

2. Set or reset the WebAdmin Console password interactively:

    ```sh
    docker compose exec ols-proxy /usr/local/lsws/admin/misc/admpass.sh
    ```

## Support and feedback

If you still have a question after using OpenLiteSpeed Docker, you have a few options:

- Join [the GoLiteSpeed Slack community](https://litespeedtech.com/slack) for real-time discussion.
- Post to [the OpenLiteSpeed Forums](https://forum.openlitespeed.org/) for community support.
- Report issues in the [GitHub `ols-proxy-docker-env` project](https://github.com/litespeedtech/ols-proxy-docker-env/issues).

**_Pull requests are always welcome!_**