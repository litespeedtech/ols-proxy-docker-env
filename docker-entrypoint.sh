#!/usr/bin/env bash
set -Eeuo pipefail

: "${BACKEND_IP:?BACKEND_IP is required}"
: "${BACKEND_PORT:?BACKEND_PORT is required}"
: "${DOMAIN:?DOMAIN is required}"

PROXY_SOCKET="${PROXY_SOCKET:-false}"
PROXY_SOCKET_IP="${PROXY_SOCKET_IP:-$BACKEND_IP}"
PROXY_SOCKET_PORT="${PROXY_SOCKET_PORT:-$BACKEND_PORT}"
PROXY_METHOD="${PROXY_METHOD:-rewrite}"
HEADER_SET="${HEADER_SET:-}"
THROTTLING="${THROTTLING:-false}"
RECAPTCHA="${RECAPTCHA:-false}"
MODSECURITY="${MODSECURITY:-false}"
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

validate_nonnegative_integer() {
    local name="$1"
    local value="$2"
    if [[ ! "$value" =~ ^[0-9]+$ ]] || (( 10#$value > 2147483647 )); then
        echo "$name must be a non-negative integer no greater than 2147483647" >&2
        exit 1
    fi
}

validate_positive_integer() {
    local name="$1"
    local value="$2"
    validate_nonnegative_integer "$name" "$value"
    if (( 10#$value == 0 )); then
        echo "$name must be greater than zero" >&2
        exit 1
    fi
}

normalize_recaptcha_type() {
    local value="${1,,}"
    case "$value" in
        checkbox|1) printf '%s' 1 ;;
        invisible|2) printf '%s' 2 ;;
        hcaptcha|3) printf '%s' 3 ;;
        *)
            echo "RECAPTCHA_TYPE must be checkbox, invisible, hcaptcha, 1, 2, or 3" >&2
            exit 1
            ;;
    esac
}

validate_recaptcha_key() {
    local name="$1"
    local value="$2"
    # Keys are inserted into an OLS config file. Restrict them to opaque token
    # characters so an environment value cannot add a directive or a block.
    if [[ ! "$value" =~ ^[A-Za-z0-9_-]{20,512}$ ]]; then
        echo "$name must be a 20-512 character CAPTCHA key containing only letters, digits, _ or -" >&2
        exit 1
    fi
}

write_security_config() {
    local config_file="$1"
    local throttling_static throttling_dynamic throttling_out throttling_in
    local throttling_soft throttling_hard throttling_grace throttling_ban throttling_block
    local recaptcha_type recaptcha_site_key recaptcha_secret_key recaptcha_max_tries
    local recaptcha_robot_hits recaptcha_connection_limit recaptcha_ssl_connection_limit

    throttling_static="${THROTTLING_STATIC_REQ_PER_SEC:-40}"
    throttling_dynamic="${THROTTLING_DYNAMIC_REQ_PER_SEC:-20}"
    throttling_out="${THROTTLING_OUT_BANDWIDTH:-0}"
    throttling_in="${THROTTLING_IN_BANDWIDTH:-0}"
    throttling_soft="${THROTTLING_SOFT_LIMIT:-15}"
    throttling_hard="${THROTTLING_HARD_LIMIT:-20}"
    throttling_grace="${THROTTLING_GRACE_PERIOD:-15}"
    throttling_ban="${THROTTLING_BAN_PERIOD:-60}"
    throttling_block="${THROTTLING_BLOCK_BAD_REQUEST:-true}"

    if [[ "${THROTTLING,,}" == true ]]; then
        validate_nonnegative_integer THROTTLING_STATIC_REQ_PER_SEC "$throttling_static"
        validate_nonnegative_integer THROTTLING_DYNAMIC_REQ_PER_SEC "$throttling_dynamic"
        validate_nonnegative_integer THROTTLING_OUT_BANDWIDTH "$throttling_out"
        validate_nonnegative_integer THROTTLING_IN_BANDWIDTH "$throttling_in"
        validate_positive_integer THROTTLING_SOFT_LIMIT "$throttling_soft"
        validate_positive_integer THROTTLING_HARD_LIMIT "$throttling_hard"
        validate_positive_integer THROTTLING_GRACE_PERIOD "$throttling_grace"
        validate_positive_integer THROTTLING_BAN_PERIOD "$throttling_ban"
        validate_socket THROTTLING_BLOCK_BAD_REQUEST "$throttling_block"
        if (( 10#$throttling_soft > 10#$throttling_hard )); then
            echo "THROTTLING_SOFT_LIMIT cannot exceed THROTTLING_HARD_LIMIT" >&2
            exit 1
        fi
        [[ "${throttling_block,,}" == true ]] && throttling_block=1 || throttling_block=0
    else
        throttling_static=0 throttling_dynamic=0 throttling_out=0 throttling_in=0
        throttling_soft=10000 throttling_hard=10000 throttling_block=0 throttling_grace=15 throttling_ban=300
    fi

    cat > "$config_file" <<EOF
# Generated from global .env security settings. Do not edit.
perClientConnLimit {
    staticReqPerSec         $throttling_static
    dynReqPerSec            $throttling_dynamic
    outBandwidth            $throttling_out
    inBandwidth             $throttling_in
    softLimit               $throttling_soft
    hardLimit               $throttling_hard
    blockBadReq             $throttling_block
    gracePeriod             $throttling_grace
    banPeriod               $throttling_ban
}
EOF

    if [[ "${RECAPTCHA,,}" == true ]]; then
        recaptcha_type="$(normalize_recaptcha_type "${RECAPTCHA_TYPE:-invisible}")"
        recaptcha_site_key="${RECAPTCHA_SITE_KEY:-}"
        recaptcha_secret_key="${RECAPTCHA_SECRET_KEY:-}"
        recaptcha_max_tries="${RECAPTCHA_MAX_TRIES:-3}"
        recaptcha_robot_hits="${RECAPTCHA_ALLOWED_ROBOT_HITS:-3}"
        recaptcha_connection_limit="${RECAPTCHA_CONNECTION_LIMIT:-15000}"
        recaptcha_ssl_connection_limit="${RECAPTCHA_SSL_CONNECTION_LIMIT:-10000}"
        validate_recaptcha_key RECAPTCHA_SITE_KEY "$recaptcha_site_key"
        validate_recaptcha_key RECAPTCHA_SECRET_KEY "$recaptcha_secret_key"
        validate_positive_integer RECAPTCHA_MAX_TRIES "$recaptcha_max_tries"
        validate_nonnegative_integer RECAPTCHA_ALLOWED_ROBOT_HITS "$recaptcha_robot_hits"
        validate_positive_integer RECAPTCHA_CONNECTION_LIMIT "$recaptcha_connection_limit"
        validate_positive_integer RECAPTCHA_SSL_CONNECTION_LIMIT "$recaptcha_ssl_connection_limit"
        cat >> "$config_file" <<EOF

lsrecaptcha {
    enabled                 1
    siteKey                 $recaptcha_site_key
    secretKey               $recaptcha_secret_key
    type                    $recaptcha_type
    maxTries                $recaptcha_max_tries
    allowedRobotHits        $recaptcha_robot_hits
    regConnLimit            $recaptcha_connection_limit
    sslConnLimit            $recaptcha_ssl_connection_limit
}
EOF
    else
        cat >> "$config_file" <<'EOF'

lsrecaptcha {
    enabled                 0
}
EOF
    fi

    if [[ "${MODSECURITY,,}" == true ]]; then
        local owasp_version_file=/opt/ols-proxy/owasp/.version
        [[ -r "$owasp_version_file" ]] || { echo "The image does not contain an OWASP CRS version record" >&2; exit 1; }
        local owasp_crs_version
        owasp_crs_version="$(<"$owasp_version_file")"
        if [[ ! "$owasp_crs_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "The image contains an invalid OWASP CRS version record" >&2
            exit 1
        fi
        local crs_root="/opt/ols-proxy/owasp/$owasp_crs_version"
        [[ -f /opt/ols-proxy/mod_security.so ]] || { echo "ModSecurity module asset is missing from this image" >&2; exit 1; }
        [[ -f "$crs_root/modsec_includes.conf" ]] || {
            echo "OWASP CRS $owasp_crs_version is incomplete in this image; rebuild the proxy image" >&2
            exit 1
        }
        install -D -m 0644 /opt/ols-proxy/mod_security.so "$SERVER_ROOT/modules/mod_security.so"
        cat >> "$config_file" <<EOF

module mod_security {
    modsecurity              on
    modsecurity_rules_file   $crs_root/modsec_includes.conf
    ls_enabled               1
}
EOF
    fi
}

normalize_proxy_method() {
    local name="$1"
    local value="${2,,}"
    case "$value" in
        r|rewrite)
            printf '%s' rewrite
            ;;
        c|context)
            printf '%s' context
            ;;
        *)
            echo "$name must be R, rewrite, C, or context (case-insensitive)" >&2
            exit 1
            ;;
    esac
}

normalize_header_operation() {
    local name="$1"
    local value="$2"
    local method="$3"
    local safe_unquoted_value="^[-A-Za-z0-9 :/._?&=%+@#;,()'!*|~]+$"
    local safe_quoted_value="^\"[-A-Za-z0-9 :/._?&=%+@#;,()'!*|~]*\"$"
    local directive
    local operation
    local arguments
    local first
    local second
    local remainder
    local normalized
    local header_name
    local header_value

    [[ -z "$value" ]] && return
    if [[ "$method" != context ]]; then
        echo "WARNING: $name is ignored because PROXY_METHOD is $method; header operations require context" >&2
        return
    fi

    if [[ ${#value} -gt 1024 ]] || [[ "$value" == *$'\r'* || "$value" == *$'\n'* ]]; then
        echo "$name contains an unsupported character or is longer than 1024 characters" >&2
        exit 1
    fi

    if [[ "$value" == NONE ]]; then
        printf '%s' NONE
        return
    fi

    read -r first second remainder <<< "$value"
    case "${first,,}" in
        header|requestheader)
            [[ "${first,,}" == requestheader ]] && directive=RequestHeader || directive=Header
            operation="${second,,}"
            arguments="$(trim "$remainder")"
            ;;
        set|append|merge|add|unset)
            directive=Header
            operation="${first,,}"
            arguments="$(trim "$second $remainder")"
            ;;
        *)
            directive=Header
            operation=set
            arguments="$value"
            ;;
    esac

    case "$operation" in
        unset)
            read -r header_name remainder <<< "$arguments"
            if [[ -z "$header_name" || -n "$remainder" ]]; then
                echo "$name must contain one valid Header or RequestHeader operation" >&2
                exit 1
            fi
            ;;
        set|append|merge|add)
            read -r header_name header_value <<< "$arguments"
            header_value="$(trim "$header_value")"
            if [[ -z "$header_name" || -z "$header_value" ]] ||
               ! [[ "$header_value" =~ $safe_unquoted_value || "$header_value" =~ $safe_quoted_value ]]; then
                echo "$name must contain one valid Header or RequestHeader operation" >&2
                exit 1
            fi
            ;;
        *)
            echo "$name must contain one valid Header or RequestHeader operation" >&2
            exit 1
            ;;
    esac

    header_name="${header_name%:}"
    if ! [[ "$header_name" =~ ^[A-Za-z0-9-]+$ ]]; then
        echo "$name must contain one valid Header or RequestHeader operation" >&2
        exit 1
    fi

    normalized="$directive $operation $header_name"
    [[ "$operation" != unset ]] && normalized+=" $header_value"
    header_name="${header_name,,}"

    case "$header_name" in
        host|content-length|transfer-encoding|connection|te|trailer|upgrade|proxy-authorization|proxy-authenticate)
            echo "$name cannot modify the reserved $header_name header" >&2
            exit 1
            ;;
    esac

    printf '%s' "$normalized"
}

validate_domain "$DOMAIN"
validate_host "$BACKEND_IP"
validate_port BACKEND_PORT "$BACKEND_PORT"
validate_socket PROXY_SOCKET "$PROXY_SOCKET"
validate_socket THROTTLING "$THROTTLING"
validate_socket RECAPTCHA "$RECAPTCHA"
validate_socket MODSECURITY "$MODSECURITY"
PROXY_METHOD="$(normalize_proxy_method PROXY_METHOD "$PROXY_METHOD")"
HEADER_SET="$(normalize_header_operation HEADER_SET "$HEADER_SET" "$PROXY_METHOD")"

if [[ "${PROXY_SOCKET,,}" == true ]]; then
    validate_host "$PROXY_SOCKET_IP"
    validate_port PROXY_SOCKET_PORT "$PROXY_SOCKET_PORT"
fi

declare -a DOMAINS=("$DOMAIN")
declare -a BACKENDS=("$BACKEND_IP")
declare -a BACKEND_PORTS=("$BACKEND_PORT")
declare -a SOCKETS=("${PROXY_SOCKET,,}")
declare -a PROXY_METHODS=("$PROXY_METHOD")
declare -a HEADER_SETS=("$HEADER_SET")
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
        if (( field_count < 4 )); then
            echo "$DOMAINS_CONFIG:$line_number must contain at least 4 comma-separated fields" >&2
            exit 1
        fi

        IFS=',' read -r domain backend backend_port socket proxy_method header_set <<< "$line"
        domain="$(trim "$domain")"
        backend="$(trim "$backend")"
        backend_port="$(trim "$backend_port")"
        socket="$(trim "$socket")"
        proxy_method="$(trim "${proxy_method:-}")"
        header_set="$(trim "${header_set:-}")"

        if (( field_count == 4 )); then
            proxy_method=rewrite
        elif [[ -z "$proxy_method" ]]; then
            echo "$DOMAINS_CONFIG:$line_number has an empty PROXY_METHOD value" >&2
            exit 1
        fi

        [[ -n "$domain" ]] || { echo "$DOMAINS_CONFIG:$line_number has an empty domain" >&2; exit 1; }
        [[ -n "$backend" ]] || { echo "$DOMAINS_CONFIG:$line_number has an empty backend host" >&2; exit 1; }
        [[ -n "$backend_port" ]] || { echo "$DOMAINS_CONFIG:$line_number has an empty backend port" >&2; exit 1; }
        [[ -n "$socket" ]] || { echo "$DOMAINS_CONFIG:$line_number has an empty PROXY_SOCKET value" >&2; exit 1; }

        validate_domain "$domain"
        validate_host "$backend"
        validate_port "$DOMAINS_CONFIG:$line_number backend port" "$backend_port"
        validate_socket "$DOMAINS_CONFIG:$line_number PROXY_SOCKET" "$socket"
        proxy_method="$(normalize_proxy_method "$DOMAINS_CONFIG:$line_number PROXY_METHOD" "$proxy_method")"
        header_set="$(normalize_header_operation "$DOMAINS_CONFIG:$line_number HEADER_SET" "$header_set" "$proxy_method")"

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
        PROXY_METHODS+=("$proxy_method")
        HEADER_SETS+=("$header_set")
        VH_NAMES+=("$vh_name")
    done < "$DOMAINS_CONFIG"
fi

SERVER_ROOT=/usr/local/lsws
CONF_ROOT="$SERVER_ROOT/conf"
BASE_CONFIG="$CONF_ROOT/httpd_config.conf.ols-proxy-base"
GENERATED_SECURITY_CONFIG="$CONF_ROOT/security_config.conf"

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

write_security_config "$GENERATED_SECURITY_CONFIG"

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

/^[[:space:]]*(listener|vhTemplate|lsrecaptcha|perClientConnLimit)[[:space:]]+[^\{]+\{/ || /^[[:space:]]*module[[:space:]]+mod_security[[:space:]]*\{/ {
    block_depth = brace_delta($0)
    skip_block = 1
    next
}

{ print }
' "$BASE_CONFIG" > "$CONF_ROOT/httpd_config.conf.tmp"

cat "$GENERATED_SECURITY_CONFIG" >> "$CONF_ROOT/httpd_config.conf.tmp"

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
    proxy_method="${PROXY_METHODS[$index]}"
    header_set="${HEADER_SETS[$index]}"
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
    logLevel              ERROR
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

EOF

    if [[ "$proxy_method" == rewrite ]]; then
        cat >> "$vhost_conf" <<EOF

rewrite  {
    enable                  1
    autoLoadHtaccess        0
    logLevel                0
    RewriteCond             %{REQUEST_URI} !^/\.well-known/acme-challenge/
    RewriteRule             ^(.*)$ HTTP://$proxy_name/\$1 [P,L,E=PROXY-HOST:${domain}]
}
EOF
    else
        cat >> "$vhost_conf" <<EOF

context /.well-known/acme-challenge/ {
    type                    static
    location                $vhost_root/html/.well-known/acme-challenge/
    allowBrowse             1
}

context / {
    type                    proxy
    handler                 $proxy_name
EOF
        if [[ -n "$header_set" ]]; then
            printf '    extraHeaders            %s\n' "$header_set" >> "$vhost_conf"
        fi
        cat >> "$vhost_conf" <<EOF
}
EOF
    fi

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
