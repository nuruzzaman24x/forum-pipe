#!/bin/bash

# ============================================================
# Forum Pipe - Worker Provisioning
# Target: worker01
# OS: Ubuntu 24.04
# Deployment: Non-Docker
# Web: Nginx
# PHP: 8.1
# Node.js: 18
# Database: MySQL 8
# ============================================================

set -euo pipefail

PHP_VERSION="8.1"
NODE_MAJOR="18"

APP_NAME="Forum Pipe"
APP_DOMAIN="forum.local"

DEPLOY_PATH="/var/www/forum-pipe"
RELEASES_PATH="${DEPLOY_PATH}/releases"
SHARED_PATH="${DEPLOY_PATH}/shared"
CURRENT_PATH="${DEPLOY_PATH}/current"

DB_NAME="forum"
DB_USER="forum_user"
DB_PASSWORD="forum_password"

NGINX_CONF="/etc/nginx/sites-available/forum-pipe"
NGINX_LINK="/etc/nginx/sites-enabled/forum-pipe"

echo
echo "============================================================"
echo " Forum Pipe - Worker Provisioning"
echo "============================================================"
echo " Host:          $(hostname)"
echo " PHP:           ${PHP_VERSION}"
echo " Node.js:       ${NODE_MAJOR}"
echo " Deploy path:   ${DEPLOY_PATH}"
echo "============================================================"
echo


# ============================================================
# Root check
# ============================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must run as root."
    echo "Use: sudo deploy/provision-worker.sh"
    exit 1
fi


# ============================================================
# APT prerequisites
# ============================================================

echo "==> Installing base packages..."

export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y \
    ca-certificates \
    curl \
    wget \
    gnupg \
    dirmngr \
    lsb-release \
    apt-transport-https \
    software-properties-common \
    unzip \
    rsync \
    git \
    build-essential


# ============================================================
# PHP 8.1 repository
# ============================================================

echo "==> Checking PHP ${PHP_VERSION} repository..."

if ! command -v "php${PHP_VERSION}" >/dev/null 2>&1; then

    mkdir -p /etc/apt/keyrings

    if [ ! -f /etc/apt/keyrings/ondrej-php.gpg ]; then
        echo "==> Adding Ondrej PHP repository key..."

        gpg \
            --no-default-keyring \
            --keyring /etc/apt/keyrings/ondrej-php.gpg \
            --keyserver hkp://keyserver.ubuntu.com:80 \
            --recv-keys \
            4F4EA0AAE5267A6C \
            71DAEAAB4AD4CAB6
    fi

    if [ ! -f /etc/apt/sources.list.d/ondrej-php.list ]; then

        echo "deb [signed-by=/etc/apt/keyrings/ondrej-php.gpg] https://ppa.launchpadcontent.net/ondrej/php/ubuntu $(lsb_release -cs) main" \
            > /etc/apt/sources.list.d/ondrej-php.list
    fi

    apt-get update

    echo "==> Installing PHP ${PHP_VERSION}..."

    apt-get install -y \
        "php${PHP_VERSION}" \
        "php${PHP_VERSION}-cli" \
        "php${PHP_VERSION}-common" \
        "php${PHP_VERSION}-fpm" \
        "php${PHP_VERSION}-mysql" \
        "php${PHP_VERSION}-mbstring" \
        "php${PHP_VERSION}-xml" \
        "php${PHP_VERSION}-curl" \
        "php${PHP_VERSION}-zip" \
        "php${PHP_VERSION}-gd" \
        "php${PHP_VERSION}-bcmath" \
        "php${PHP_VERSION}-intl"
else
    echo "PHP ${PHP_VERSION} already installed."
fi


# ============================================================
# PHP CLI / FPM defaults
# ============================================================

echo "==> Checking PHP ${PHP_VERSION}..."

php${PHP_VERSION} -v

systemctl enable --now "php${PHP_VERSION}-fpm"


# ============================================================
# Composer
# ============================================================

echo "==> Checking Composer..."

if ! command -v composer >/dev/null 2>&1; then

    echo "==> Installing Composer..."

    EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)"

    curl -fsSL https://getcomposer.org/installer \
        -o /tmp/composer-setup.php

    ACTUAL_SIGNATURE="$(
        php${PHP_VERSION} -r \
        "echo hash_file('sha384', '/tmp/composer-setup.php');"
    )"

    if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
        echo "ERROR: Composer installer signature verification failed."
        rm -f /tmp/composer-setup.php
        exit 1
    fi

    php${PHP_VERSION} /tmp/composer-setup.php \
        --install-dir=/usr/local/bin \
        --filename=composer

    rm -f /tmp/composer-setup.php

    chmod +x /usr/local/bin/composer
else
    echo "Composer already installed."
fi

composer --version


# ============================================================
# Node.js 18
# ============================================================

echo "==> Checking Node.js..."

NODE_OK=false

if command -v node >/dev/null 2>&1; then

    INSTALLED_NODE_MAJOR="$(
        node -p "process.versions.node.split('.')[0]"
    )"

    if [ "$INSTALLED_NODE_MAJOR" = "$NODE_MAJOR" ]; then
        NODE_OK=true
        echo "Node.js ${NODE_MAJOR} already installed."
    fi
fi

if [ "$NODE_OK" = false ]; then

    echo "==> Installing Node.js ${NODE_MAJOR}..."

    curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x \
        | bash -

    apt-get install -y nodejs
fi

echo "Node.js:"
node --version

echo "npm:"
npm --version


# ============================================================
# MySQL
# ============================================================

echo "==> Checking MySQL..."

if ! command -v mysql >/dev/null 2>&1; then
    echo "==> Installing MySQL..."

    apt-get install -y mysql-server
fi

systemctl enable --now mysql

echo "MySQL:"
mysql --version


# ============================================================
# Create application database and user
# ============================================================

echo "==> Ensuring MySQL database exists..."

mysql --protocol=socket -uroot <<MYSQL
CREATE DATABASE IF NOT EXISTS ${DB_NAME}
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost'
    IDENTIFIED BY '${DB_PASSWORD}';

ALTER USER '${DB_USER}'@'localhost'
    IDENTIFIED BY '${DB_PASSWORD}';

GRANT ALL PRIVILEGES
    ON ${DB_NAME}.*
    TO '${DB_USER}'@'localhost';

FLUSH PRIVILEGES;
MYSQL

echo "Database: ${DB_NAME}"
echo "User:     ${DB_USER}"


# ============================================================
# Nginx
# ============================================================

echo "==> Checking Nginx..."

if ! command -v nginx >/dev/null 2>&1; then

    echo "==> Installing Nginx..."

    apt-get install -y nginx
fi


# ============================================================
# Disable Apache if present
# ============================================================

if systemctl list-unit-files 2>/dev/null | grep -q '^apache2.service'; then

    echo "==> Apache detected."

    systemctl stop apache2 2>/dev/null || true
    systemctl disable apache2 2>/dev/null || true

fi


# ============================================================
# Create deployment directories
# ============================================================

echo "==> Creating deployment directories..."

mkdir -p \
    "${DEPLOY_PATH}" \
    "${RELEASES_PATH}" \
    "${SHARED_PATH}" \
    "${SHARED_PATH}/storage" \
    "${SHARED_PATH}/storage/app" \
    "${SHARED_PATH}/storage/framework" \
    "${SHARED_PATH}/storage/framework/cache" \
    "${SHARED_PATH}/storage/framework/sessions" \
    "${SHARED_PATH}/storage/framework/views" \
    "${SHARED_PATH}/storage/logs"


# ============================================================
# Permissions
# ============================================================

echo "==> Setting deployment permissions..."

chown -R deployer:www-data "${DEPLOY_PATH}"

find "${DEPLOY_PATH}" \
    -type d \
    -exec chmod 775 {} \;

find "${DEPLOY_PATH}" \
    -type f \
    -exec chmod 664 {} \;


# ============================================================
# Nginx configuration
# ============================================================

echo "==> Writing Nginx configuration..."

cat > "${NGINX_CONF}" <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    server_name ${APP_DOMAIN} 172.17.0.232 _;

    root ${CURRENT_PATH}/public;

    index index.php index.html;

    charset utf-8;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico {
        access_log off;
        log_not_found off;
    }

    location = /robots.txt {
        access_log off;
        log_not_found off;
    }

    location ~ \.php$ {
        try_files \$uri =404;

        include fastcgi_params;

        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT \$realpath_root;

        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;

        fastcgi_index index.php;

        fastcgi_read_timeout 120;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF


# ============================================================
# Enable Nginx site
# ============================================================

ln -sfn "${NGINX_CONF}" "${NGINX_LINK}"

rm -f /etc/nginx/sites-enabled/default


# ============================================================
# Test Nginx
# ============================================================

echo "==> Testing Nginx configuration..."

nginx -t


# ============================================================
# Enable services
# ============================================================

echo "==> Enabling services..."

systemctl enable --now nginx
systemctl enable --now "php${PHP_VERSION}-fpm"
systemctl enable --now mysql


# ============================================================
# Final permissions
# ============================================================

chown -R deployer:www-data "${DEPLOY_PATH}"

chmod 775 "${DEPLOY_PATH}"
chmod 775 "${RELEASES_PATH}"
chmod 775 "${SHARED_PATH}"
chmod 775 "${SHARED_PATH}/storage"


# ============================================================
# Reload services
# ============================================================

echo "==> Reloading PHP-FPM..."

systemctl reload "php${PHP_VERSION}-fpm"

echo "==> Reloading Nginx..."

systemctl reload nginx


# ============================================================
# Final verification
# ============================================================

echo
echo "============================================================"
echo " Provisioning completed successfully"
echo "============================================================"

echo
echo "PHP:"
php${PHP_VERSION} -v | head -n 1

echo
echo "Composer:"
composer --version

echo
echo "Node:"
node --version

echo
echo "npm:"
npm --version

echo
echo "MySQL:"
systemctl is-active mysql

echo
echo "PHP-FPM:"
systemctl is-active "php${PHP_VERSION}-fpm"

echo
echo "Nginx:"
systemctl is-active nginx

echo
echo "Deployment directories:"
ls -ld \
    "${DEPLOY_PATH}" \
    "${RELEASES_PATH}" \
    "${SHARED_PATH}"

echo
echo "============================================================"
echo " Worker01 is ready for Forum Pipe deployment"
echo "============================================================"
