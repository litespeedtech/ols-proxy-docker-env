ARG OLS_IMAGE=litespeedtech/openlitespeed:latest
FROM ${OLS_IMAGE}

ARG OWASP_CRS_VERSION=4.21.0

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git ols-modsecurity tar \
    && rm -rf /var/lib/apt/lists/*

RUN printf '%s\n' "$OWASP_CRS_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || { echo "OWASP_CRS_VERSION must be a numeric x.y.z release" >&2; exit 1; }

RUN install -D -m 0644 /usr/local/lsws/modules/mod_security.so /opt/ols-proxy/mod_security.so \
    && mkdir -p /opt/ols-proxy/owasp/"$OWASP_CRS_VERSION" \
    && curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
        "https://github.com/coreruleset/coreruleset/archive/refs/tags/v${OWASP_CRS_VERSION}.tar.gz" \
        -o /tmp/owasp-crs.tar.gz \
    && tar -xzf /tmp/owasp-crs.tar.gz --strip-components=1 -C /opt/ols-proxy/owasp/"$OWASP_CRS_VERSION" \
    && rm -f /tmp/owasp-crs.tar.gz \
    && test -f /opt/ols-proxy/owasp/"$OWASP_CRS_VERSION"/crs-setup.conf.example \
    && cp /opt/ols-proxy/owasp/"$OWASP_CRS_VERSION"/crs-setup.conf.example /opt/ols-proxy/owasp/"$OWASP_CRS_VERSION"/crs-setup.conf \
    && printf '%s\n' \
        'SecRuleEngine On' \
        'SecRequestBodyAccess On' \
        'SecResponseBodyAccess Off' \
        "Include /opt/ols-proxy/owasp/$OWASP_CRS_VERSION/crs-setup.conf" \
        "Include /opt/ols-proxy/owasp/$OWASP_CRS_VERSION/rules/*.conf" \
        > /opt/ols-proxy/owasp/"$OWASP_CRS_VERSION"/modsec_includes.conf \
    && printf '%s\n' "$OWASP_CRS_VERSION" > /opt/ols-proxy/owasp/.version

COPY docker-entrypoint.sh /usr/local/bin/ols-proxy-entrypoint.sh
COPY domains.conf /etc/ols-proxy/domains.conf
RUN sed -i 's/\r$//' /usr/local/bin/ols-proxy-entrypoint.sh \
    && chmod +x /usr/local/bin/ols-proxy-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/ols-proxy-entrypoint.sh"]
