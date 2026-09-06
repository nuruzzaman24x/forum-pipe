#!/bin/bash
# provision-worker.sh
# Idempotent provisioning script for worker01 (Laravel deploy target)
# Uses Nginx + PHP-FPM (not Apache). Safe to run repeatedly.
set -euo pipefail

PHP_VERSION="8.1"
APP_DOMAIN="forum.local"
DEPLOY_PATH="/var/www/forum-pipe"

echo "== Checking PHP ${PHP_VERSION} =="
if ! command -v "php${PHP_VERSION}" &>/dev/null; then
    echo "php${PHP_VERSION} not found, installing..."

    apt-get install -y dirmngr gnupg ca-certificates apt-transport-https lsb-release

    mkdir -p /etc/apt/keyrings
    if [ ! -f /etc/apt/keyrings/ondrej-php.gpg ]; then
        gpg --no-default-keyring --keyring /etc/apt/keyrings/ondrej-php.gpg \
            --keyserver hkp://keyserver.ubuntu.com:80 \
            --recv-keys 4F4EA0AAE5267A6C 71DAEAAB4AD4CAB6
    fi

    if [ ! -f /etc/apt/sources.list.d/ondrej-php.list ]; then
        echo "deb [signed-by=/etc/apt/keyrings/ondrej-php.gpg] https://ppa.launchpadcontent.net/ondrej/php/ubuntu $(lsb_release -cs) main" \
            > /etc/apt/sources.list.d/ondrej-php.list
    fi

    apt-get update
    apt-get install -y \
        "php${PHP_VERSION}" "php${PHP_VERSION}-common" "php${PHP_VERSION}-cli" "php${PHP_VERSION}-fpm" \
        "php${PHP_VERSION}-mysql" "php${PHP_VERSION}-mbstring" "php${PHP_VERSION}-xml" \
        "php${PHP_VERSION}-curl" "php${PHP_VERSION}-zip" "php${PHP_VERSION}-gd" \
        "php${PHP_VERSION}-bcmath" unzip
else
    echo "php${PHP_VERSION} already installed, skipping."
fi

echo "== Checking Composer =="
if ! command -v composer &>/dev/null; then
    echo "Composer not found, installing..."
    curl -sS https://getcomposer.org/installer | "php${PHP_VERSION}"
    mv composer.phar /usr/local/bin/composer
    chmod +x /usr/local/bin/composer
else
    echo "Composer already installed, skipping."
fi

echo "== Checking MySQL =="
if ! systemctl is-active --quiet mysql; then
    echo "MySQL not running, installing/starting..."
    apt-get install -y mysql-server
    systemctl enable --now mysql
else
    echo "MySQL already running, skipping."
fi

echo "== Checking Nginx =="
if ! command -v nginx &>/dev/null; then
    echo "Nginx not found, installing..."
    apt-get install -y nginx

    # Apache যদি আগে থেকে ইনস্টল থাকে, port 80 নিয়ে conflict এড়াতে বন্ধ ও disable করে দিন
    if systemctl list-unit-files | grep -q '^apache2.service'; then
        echo "Apache found, disabling to free up port 80..."
        systemctl stop apache2 || true
        systemctl disable apache2 || true
    fi
else
    echo "Nginx already installed, skipping."
fi

echo "== Ensuring PHP-FPM is running =="
systemctl enable --now "php${PHP_VERSION}-fpm"
systemctl restart "php${PHP_VERSION}-fpm"

echo "== Writing Nginx site config =="
NGINX_CONF="/etc/nginx/sites-available/forum-pipe"
cat > "${NGINX_CONF}" <<EOF
server {
    listen 80;
    server_name ${APP_DOMAIN};
    root ${DEPLOY_PATH}/public;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    index index.php;

    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ \.php\$ {
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF

ln -sf "${NGINX_CONF}" /etc/nginx/sites-enabled/forum-pipe
rm -f /etc/nginx/sites-enabled/default

echo "== Testing and reloading Nginx =="
nginx -t
systemctl enable --now nginx
systemctl reload nginx

echo "== Provisioning complete =="
"php${PHP_VERSION}" -v
nginx -v
