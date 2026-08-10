#!/usr/bin/env bash
set -Eeuo pipefail

: "${BACKEND_IP:?BACKEND_IP is required}"
: "${BACKEND_PORT:?BACKEND_PORT is required}"
: "${DOMAIN:?DOMAIN is required}"

PROXY_SOCKET="${PROXY_SOCKET:-false}"
PROXY_SOCKET_IP="${PROXY_SOCKET_IP:-$BACKEND_IP}"
PROXY_SOCKET_PORT="${PROXY_SOCKET_PORT:-$BACKEND_PORT}"
DOMAINS_CONFIG=/etc/ols-proxy/domains.conf

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

validate_domain() {
    local domain="$1"
    if [[ ${#domain} -gt 253 ]] || [[ ! "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]; then
        echo "Invalid domain: $domain" >&2
        exit 1
    fi
}

validate_host() {
    local host="$1"
    if [[ ! "$host" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
        echo "Invalid backend host: $host" >&2
        exit 1
    fi
}

validate_port() {
    local name="$1"
    local port="$2"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        echo "$name must be an integer between 1 and 65535" >&2
        exit 1
    fi
}

validate_socket() {
    local name="$1"
    local value="${2,,}"
    if [[ "$value" != true && "$value" != false ]]; then
        echo "$name must be true or false" >&2
        exit 1
    fi
}

validate_domain "$DOMAIN"
validate_host "$BACKEND_IP"
validate_port BACKEND_PORT "$BACKEND_PORT"
validate_socket PROXY_SOCKET "$PROXY_SOCKET"

if [[ "${PROXY_SOCKET,,}" == true ]]; then
    validate_host "$PROXY_SOCKET_IP"
    validate_port PROXY_SOCKET_PORT "$PROXY_SOCKET_PORT"
fi

declare -a DOMAINS=("$DOMAIN")
declare -a BACKENDS=("$BACKEND_IP")
declare -a BACKEND_PORTS=("$BACKEND_PORT")
declare -a SOCKETS=("${PROXY_SOCKET,,}")
declare -a VH_NAMES=(Example)
declare -A SEEN_DOMAINS
declare -A SEEN_VH_NAMES
SEEN_DOMAINS["${DOMAIN,,}"]=1
SEEN_VH_NAMES[Example]=1

if [[ -e "$DOMAINS_CONFIG" && ! -f "$DOMAINS_CONFIG" ]]; then
    echo "$DOMAINS_CONFIG must be a regular file" >&2
    exit 1
fi

if [[ -f "$DOMAINS_CONFIG" ]]; then
    line_number=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))
        line="${line%$'\r'}"
        trimmed_line="$(trim "$line")"
        [[ -z "$trimmed_line" || "$trimmed_line" == \#* ]] && continue

        field_count="$(awk -F',' '{print NF}' <<< "$line")"
        if [[ "$field_count" != 4 ]]; then
            echo "$DOMAINS_CONFIG:$line_number must contain exactly 4 comma-separated fields" >&2
            exit 1
        fi

        IFS=',' read -r domain backend backend_port socket <<< "$line"
        domain="$(trim "$domain")"
        backend="$(trim "$backend")"
        backend_port="$(trim "$backend_port")"
        socket="$(trim "$socket")"

        [[ -n "$domain" ]] || { echo "$DOMAINS_CONFIG:$line_number has an empty domain" >&2; exit 1; }
        [[ -n "$backend" ]] || { echo "$DOMAINS_CONFIG:$line_number has an empty backend host" >&2; exit 1; }
        [[ -n "$backend_port" ]] || { echo "$DOMAINS_CONFIG:$line_number has an empty backend port" >&2; exit 1; }
        [[ -n "$socket" ]] || { echo "$DOMAINS_CONFIG:$line_number has an empty PROXY_SOCKET value" >&2; exit 1; }

        validate_domain "$domain"
        validate_host "$backend"
        validate_port "$DOMAINS_CONFIG:$line_number backend port" "$backend_port"
        validate_socket "$DOMAINS_CONFIG:$line_number PROXY_SOCKET" "$socket"

        domain_key="${domain,,}"
        if [[ -n "${SEEN_DOMAINS[$domain_key]+x}" ]]; then
            echo "Duplicate domain: $domain" >&2
            exit 1
        fi

        vh_name="VH_${domain//[^A-Za-z0-9]/_}"
        if [[ ${#vh_name} -gt 200 ]]; then
            vh_name="${vh_name:0:180}_$line_number"
        fi
        if [[ -n "${SEEN_VH_NAMES[$vh_name]+x}" ]]; then
            vh_name="${vh_name}_$line_number"
        fi

        SEEN_DOMAINS["$domain_key"]=1
        SEEN_VH_NAMES["$vh_name"]=1
        DOMAINS+=("$domain")
        BACKENDS+=("$backend")
        BACKEND_PORTS+=("$backend_port")
        SOCKETS+=("${socket,,}")
        VH_NAMES+=("$vh_name")
    done < "$DOMAINS_CONFIG"
fi

SERVER_ROOT=/usr/local/lsws
CONF_ROOT="$SERVER_ROOT/conf"
BASE_CONFIG="$CONF_ROOT/httpd_config.conf.ols-proxy-base"

if [[ ! -f "$CONF_ROOT/httpd_config.conf" ]]; then
    echo "OpenLiteSpeed configuration is missing" >&2
    exit 1
fi

if [[ ! -x "$SERVER_ROOT/admin/misc/install_acme.sh" ]]; then
    echo "OpenLiteSpeed ACME installer is missing; use an OLS 1.9+ image" >&2
    exit 1
fi

if [[ ! -f "$SERVER_ROOT/acme/acme.sh" ]]; then
    if [[ -n "${ACME_EMAIL:-}" ]]; then
        "$SERVER_ROOT/admin/misc/install_acme.sh" -e "$ACME_EMAIL"
    else
        "$SERVER_ROOT/admin/misc/install_acme.sh"
    fi
fi

mkdir -p "$CONF_ROOT/vhosts/Example" "$SERVER_ROOT/logs"

if [[ ! -f "$BASE_CONFIG" ]]; then
    cp "$CONF_ROOT/httpd_config.conf" "$BASE_CONFIG"
fi

if grep -Eq '^[[:space:]]*acme[[:space:]]+[01]$' "$BASE_CONFIG"; then
    sed -i -E 's/^([[:space:]]*acme[[:space:]]*)[01]$/\12/' "$BASE_CONFIG"
elif ! grep -Eq '^[[:space:]]*acme[[:space:]]+2$' "$BASE_CONFIG"; then
    sed -i '/^tuning[[:space:]]*{$/,/^}$/ {
        /^}$/i\
            acme                    2
    }' "$BASE_CONFIG"
fi

TLS_KEY="$SERVER_ROOT/admin/conf/webadmin.key"
TLS_CERT="$SERVER_ROOT/admin/conf/webadmin.crt"

awk '
function brace_delta(line, opens, closes) {
    opens = line
    gsub(/[^\{]/, "", opens)
    closes = line
    gsub(/[^\}]/, "", closes)
    return length(opens) - length(closes)
}

skip_block {
    block_depth += brace_delta($0)
    if (block_depth <= 0) {
        skip_block = 0
    }
    next
}

/^[[:space:]]*(listener|vhTemplate)[[:space:]]+[^\{]+\{/ {
    block_depth = brace_delta($0)
    skip_block = 1
    next
}

{ print }
' "$BASE_CONFIG" > "$CONF_ROOT/httpd_config.conf.tmp"

for index in "${!DOMAINS[@]}"; do
    vh_name="${VH_NAMES[$index]}"
    vhost_root="/var/www/vhosts/$vh_name"
    cat >> "$CONF_ROOT/httpd_config.conf.tmp" <<EOF

virtualhost $vh_name {
    vhRoot                  $vhost_root/
    configFile              conf/vhosts/$vh_name/vhconf.conf
    allowSymbolLink         1
    enableScript            1
    restrained              1
    setUIDMode              0
}
EOF
done

cat >> "$CONF_ROOT/httpd_config.conf.tmp" <<EOF

listener HTTP {
    address                 *:80
    secure                  0
EOF
for index in "${!DOMAINS[@]}"; do
    printf '    map                     %s %s\n' "${VH_NAMES[$index]}" "${DOMAINS[$index]}" >> "$CONF_ROOT/httpd_config.conf.tmp"
done
cat >> "$CONF_ROOT/httpd_config.conf.tmp" <<EOF
}

listener HTTPS {
    address                 *:443
    secure                  1
    enableQuic              1
    keyFile                 $TLS_KEY
    certFile                $TLS_CERT
    certChain               1
EOF
for index in "${!DOMAINS[@]}"; do
    printf '    map                     %s %s\n' "${VH_NAMES[$index]}" "${DOMAINS[$index]}" >> "$CONF_ROOT/httpd_config.conf.tmp"
done
cat >> "$CONF_ROOT/httpd_config.conf.tmp" <<EOF
}
EOF

mv "$CONF_ROOT/httpd_config.conf.tmp" "$CONF_ROOT/httpd_config.conf"

for index in "${!DOMAINS[@]}"; do
    domain="${DOMAINS[$index]}"
    backend="${BACKENDS[$index]}"
    backend_port="${BACKEND_PORTS[$index]}"
    socket="${SOCKETS[$index]}"
    vh_name="${VH_NAMES[$index]}"
    if [[ "$index" == 0 ]]; then
        proxy_name=proxy_backend
    else
        proxy_name="proxy_backend$((index + 1))"
    fi
    vhost_root="/var/www/vhosts/$vh_name"
    vhost_conf="$CONF_ROOT/vhosts/$vh_name/vhconf.conf"

    mkdir -p "$CONF_ROOT/vhosts/$vh_name" "$vhost_root/html" "$vhost_root/html/.well-known/acme-challenge"

    cat > "$vhost_conf" <<EOF
docRoot                 $vhost_root/html/
indexFiles              index.html

errorlog $SERVER_ROOT/logs/$vh_name.error.log {
    useServer             0
}

accesslog $SERVER_ROOT/logs/$vh_name.access.log {
    useServer             0
    rollingSize           10M
    keepDays              7
    compressArchive       1
}

vhssl {
    acme {
        enabled             2
    }
}

extprocessor $proxy_name {
    type                    proxy
    address                 http://${backend}:${backend_port}
    maxConns                100
    pcKeepAliveTimeout      60
    initTimeout             60
    retryTimeout            0
    respBuffer              0
}

rewrite  {
    enable                  1
    autoLoadHtaccess        0
    logLevel                0
    RewriteCond             %{REQUEST_URI} !^/\.well-known/acme-challenge/
    RewriteRule             ^(.*)$ HTTP://$proxy_name/\$1 [P,L,E=PROXY-HOST:${domain}]
}
EOF

    if [[ "$socket" == true ]]; then
        socket_ip="$backend"
        socket_port="$backend_port"
        if [[ "$index" == 0 ]]; then
            socket_ip="$PROXY_SOCKET_IP"
            socket_port="$PROXY_SOCKET_PORT"
        fi
        cat >> "$vhost_conf" <<EOF

websocket / {
    address                 ${socket_ip}:${socket_port}
}
EOF
    fi
done

chown -R lsadm:lsadm "$CONF_ROOT"
chown -R root:root /var/www/vhosts
chmod -R u=rwX,go=rX /var/www/vhosts
chmod -R u=rwX,go= "$SERVER_ROOT/admin/conf"

"$SERVER_ROOT/bin/lswsctrl" start

while "$SERVER_ROOT/bin/lswsctrl" status | grep -q 'litespeed is running with PID'; do
    sleep 60
done

echo "OpenLiteSpeed stopped" >&2
exit 1
