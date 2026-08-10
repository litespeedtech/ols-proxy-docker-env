ARG OLS_IMAGE=litespeedtech/openlitespeed:latest
FROM ${OLS_IMAGE}

RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

COPY docker-entrypoint.sh /usr/local/bin/ols-proxy-entrypoint.sh
COPY domains.conf /etc/ols-proxy/domains.conf
RUN chmod +x /usr/local/bin/ols-proxy-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/ols-proxy-entrypoint.sh"]
