#!/bin/bash

# ============================================================
# Forum Pipe - Worker Provisioning (idempotent, safe to re-run)
# OS: Ubuntu 24.04 / 22.04
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
    echo "Use: sudo bash deploy/provision-worker.sh"
    exit 1
fi


# ============================================================
# Deployment user
# ============================================================
#
# This works for ANY sudo user (nuruzzaman, devops, whoever
# runs the self-hosted GitHub Actions runner) — it is never
# hardcoded. SUDO_USER is set automatically by sudo to whoever
# invoked "sudo bash provision-worker.sh".
# ============================================================

if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    DEPLOY_USER="${SUDO_USER}"
else
    DEPLOY_USER="$(stat -c '%U' /opt/actions-runner 2>/dev/null || true)"
fi

if [ -z "${DEPLOY_USER}" ] || [ "${DEPLOY_USER}" = "root" ]; then
    echo "ERROR: Could not determine deployment user."
    echo "This script should be executed through sudo by the GitHub Actions runner user."
    exit 1
fi

if ! id "${DEPLOY_USER}" >/dev/null 2>&1; then
    echo "ERROR: Deployment user '${DEPLOY_USER}' does not exist."
    exit 1
fi

echo "Deployment user: ${DEPLOY_USER}"


# ============================================================
# Fix any broken/interrupted dpkg state before doing anything
# ============================================================

echo "==> Ensuring dpkg is in a clean state..."
dpkg --configure -a || true


# ============================================================
# Remove stray/broken third-party repos that can break apt update
# ============================================================
#
# Some base images ship with unrelated repos (e.g. HashiCorp,
# added by a previous provisioning tool or manual setup) whose
# signing key is missing. This does not stop apt-get update from
# working overall, but it prints noisy errors and can eventually
# cause hard failures. We only touch it if it exists and is broken.
# ============================================================

if [ -f /etc/apt/sources.list.d/hashicorp.list ]; then
    if ! apt-key list 2>/dev/null | grep -qi "hashicorp"; then
        echo "==> Removing unreachable HashiCorp apt source (missing key)..."
        rm -f /etc/apt/sources.list.d/hashicorp.list
    fi
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
# MySQL (robust, self-healing install)
# ============================================================
#
# NOTE: We deliberately do NOT gate on
#   `systemctl list-unit-files | grep mysql.service`
# That check has proven unreliable on some self-hosted runner
# environments even when the unit file genuinely exists (the
# postinst script confirms creating the symlink, yet the grep
# still reports nothing). Instead we just try to start the
# service through the normal paths and verify success by
# actually pinging MySQL, which is the thing that really matters.
# ============================================================

echo "==> Checking MySQL..."

MYSQL_STATUS="$(dpkg-query -W -f='${Status}' mysql-server 2>/dev/null || true)"

if ! echo "$MYSQL_STATUS" | grep -q "install ok installed"; then
    echo "==> Installing MySQL Server..."
    apt-get install -y mysql-server
else
    echo "MySQL Server package already installed."
fi

echo "==> Reloading systemd unit files..."
systemctl daemon-reload || true

echo "==> Starting MySQL..."

MYSQL_STARTED=false

# Try via systemd first (most common path). Different package
# builds have used either "mysql.service" or "mysqld.service".
for unit in mysql.service mysqld.service; do
    if systemctl enable --now "$unit" >/dev/null 2>&1; then
        echo "Started via systemd unit: ${unit}"
        MYSQL_STARTED=true
        break
    fi
done

# Fallback: legacy service/init.d command, for environments
# where systemctl cannot manage the unit directly.
if [ "$MYSQL_STARTED" = false ]; then
    echo "systemctl could not start MySQL directly, trying 'service mysql start'..."
    if service mysql start >/dev/null 2>&1; then
        MYSQL_STARTED=true
    fi
fi

# Last resort: repair dpkg state and retry once.
if [ "$MYSQL_STARTED" = false ]; then
    echo "==> Repairing dpkg state and reinstalling mysql-server..."

    dpkg --configure -a || true
    apt-get install -y --reinstall mysql-server
    systemctl daemon-reload || true

    for unit in mysql.service mysqld.service; do
        if systemctl enable --now "$unit" >/dev/null 2>&1; then
            echo "Started via systemd unit: ${unit}"
            MYSQL_STARTED=true
            break
        fi
    done

    if [ "$MYSQL_STARTED" = false ]; then
        echo "Retrying 'service mysql start' after reinstall..."
        if service mysql start >/dev/null 2>&1; then
            MYSQL_STARTED=true
        fi
    fi
fi

if [ "$MYSQL_STARTED" = false ]; then
    echo "ERROR: Could not start MySQL through systemd or init.d."
    echo "---- diagnostics ----"
    dpkg -l | grep -i mysql || true
    echo "--- unit files on disk ---"
    ls -la /lib/systemd/system 2>/dev/null | grep -i mysql || echo "(none found on disk)"
    echo "--- systemctl list-unit-files (mysql) ---"
    systemctl list-unit-files 2>&1 | grep -i mysql || echo "(systemctl reported nothing)"
    echo "----------------------"
    echo "Check manually: journalctl -u mysql --no-pager | tail -n 50"
    echo "Check manually: cat /var/log/mysql/error.log"
    exit 1
fi

# Wait for MySQL to actually accept connections before configuring it.
# This is the real proof it's working, regardless of which path started it.
echo "==> Waiting for MySQL to become ready..."
for i in $(seq 1 30); do
    if mysqladmin --protocol=socket ping >/dev/null 2>&1; then
        echo "MySQL is ready."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "ERROR: MySQL did not become ready in time."
        systemctl status mysql --no-pager 2>/dev/null || true
        echo "---- last 50 lines of error log ----"
        tail -n 50 /var/log/mysql/error.log 2>/dev/null || true
        exit 1
    fi
    sleep 1
done

echo "MySQL:"
mysql --version

echo "MySQL service:"
systemctl is-active mysql 2>/dev/null || systemctl is-active mysqld 2>/dev/null || echo "unknown (started, but not tracked as a systemd unit)"


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

chown -R "${DEPLOY_USER}:www-data" "${DEPLOY_PATH}"

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

    server_name ${APP_DOMAIN} _;

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


# ============================================================
# Final permissions
# ============================================================

echo "==> Applying final permissions..."

chown -R "${DEPLOY_USER}:www-data" "${DEPLOY_PATH}"

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
echo "Deployment user: ${DEPLOY_USER}"

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
systemctl is-active mysql 2>/dev/null || systemctl is-active mysqld 2>/dev/null || echo "unknown"

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
echo " Worker is ready for Forum Pipe deployment"
echo "============================================================"


# #!/bin/bash

# # ============================================================
# # Forum Pipe - Worker Provisioning (idempotent, safe to re-run)
# # OS: Ubuntu 24.04 / 22.04
# # Deployment: Non-Docker
# # Web: Nginx
# # PHP: 8.1
# # Node.js: 18
# # Database: MySQL 8
# # ============================================================

# set -euo pipefail

# PHP_VERSION="8.1"
# NODE_MAJOR="18"

# APP_NAME="Forum Pipe"
# APP_DOMAIN="forum.local"

# DEPLOY_PATH="/var/www/forum-pipe"
# RELEASES_PATH="${DEPLOY_PATH}/releases"
# SHARED_PATH="${DEPLOY_PATH}/shared"
# CURRENT_PATH="${DEPLOY_PATH}/current"

# DB_NAME="forum"
# DB_USER="forum_user"
# DB_PASSWORD="forum_password"

# NGINX_CONF="/etc/nginx/sites-available/forum-pipe"
# NGINX_LINK="/etc/nginx/sites-enabled/forum-pipe"

# echo
# echo "============================================================"
# echo " Forum Pipe - Worker Provisioning"
# echo "============================================================"
# echo " Host:          $(hostname)"
# echo " PHP:           ${PHP_VERSION}"
# echo " Node.js:       ${NODE_MAJOR}"
# echo " Deploy path:   ${DEPLOY_PATH}"
# echo "============================================================"
# echo


# # ============================================================
# # Root check
# # ============================================================

# if [ "$(id -u)" -ne 0 ]; then
#     echo "ERROR: This script must run as root."
#     echo "Use: sudo bash deploy/provision-worker.sh"
#     exit 1
# fi


# # ============================================================
# # Deployment user
# # ============================================================
# #
# # This works for ANY sudo user (nuruzzaman, devops, whoever
# # runs the self-hosted GitHub Actions runner) — it is never
# # hardcoded. SUDO_USER is set automatically by sudo to whoever
# # invoked "sudo bash provision-worker.sh".
# # ============================================================

# if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
#     DEPLOY_USER="${SUDO_USER}"
# else
#     DEPLOY_USER="$(stat -c '%U' /opt/actions-runner 2>/dev/null || true)"
# fi

# if [ -z "${DEPLOY_USER}" ] || [ "${DEPLOY_USER}" = "root" ]; then
#     echo "ERROR: Could not determine deployment user."
#     echo "This script should be executed through sudo by the GitHub Actions runner user."
#     exit 1
# fi

# if ! id "${DEPLOY_USER}" >/dev/null 2>&1; then
#     echo "ERROR: Deployment user '${DEPLOY_USER}' does not exist."
#     exit 1
# fi

# echo "Deployment user: ${DEPLOY_USER}"


# # ============================================================
# # Fix any broken/interrupted dpkg state before doing anything
# # ============================================================

# echo "==> Ensuring dpkg is in a clean state..."
# dpkg --configure -a || true


# # ============================================================
# # Remove stray/broken third-party repos that can break apt update
# # ============================================================
# #
# # Some base images ship with unrelated repos (e.g. HashiCorp,
# # added by a previous provisioning tool or manual setup) whose
# # signing key is missing. This does not stop apt-get update from
# # working overall, but it prints noisy errors and can eventually
# # cause hard failures. We only touch it if it exists and is broken.
# # ============================================================

# if [ -f /etc/apt/sources.list.d/hashicorp.list ]; then
#     if ! apt-key list 2>/dev/null | grep -qi "hashicorp"; then
#         echo "==> Removing unreachable HashiCorp apt source (missing key)..."
#         rm -f /etc/apt/sources.list.d/hashicorp.list
#     fi
# fi


# # ============================================================
# # APT prerequisites
# # ============================================================

# echo "==> Installing base packages..."

# export DEBIAN_FRONTEND=noninteractive

# apt-get update

# apt-get install -y \
#     ca-certificates \
#     curl \
#     wget \
#     gnupg \
#     dirmngr \
#     lsb-release \
#     apt-transport-https \
#     software-properties-common \
#     unzip \
#     rsync \
#     git \
#     build-essential


# # ============================================================
# # PHP 8.1 repository
# # ============================================================

# echo "==> Checking PHP ${PHP_VERSION} repository..."

# if ! command -v "php${PHP_VERSION}" >/dev/null 2>&1; then

#     mkdir -p /etc/apt/keyrings

#     if [ ! -f /etc/apt/keyrings/ondrej-php.gpg ]; then
#         echo "==> Adding Ondrej PHP repository key..."

#         gpg \
#             --no-default-keyring \
#             --keyring /etc/apt/keyrings/ondrej-php.gpg \
#             --keyserver hkp://keyserver.ubuntu.com:80 \
#             --recv-keys \
#             4F4EA0AAE5267A6C \
#             71DAEAAB4AD4CAB6
#     fi

#     if [ ! -f /etc/apt/sources.list.d/ondrej-php.list ]; then

#         echo "deb [signed-by=/etc/apt/keyrings/ondrej-php.gpg] https://ppa.launchpadcontent.net/ondrej/php/ubuntu $(lsb_release -cs) main" \
#             > /etc/apt/sources.list.d/ondrej-php.list
#     fi

#     apt-get update

#     echo "==> Installing PHP ${PHP_VERSION}..."

#     apt-get install -y \
#         "php${PHP_VERSION}" \
#         "php${PHP_VERSION}-cli" \
#         "php${PHP_VERSION}-common" \
#         "php${PHP_VERSION}-fpm" \
#         "php${PHP_VERSION}-mysql" \
#         "php${PHP_VERSION}-mbstring" \
#         "php${PHP_VERSION}-xml" \
#         "php${PHP_VERSION}-curl" \
#         "php${PHP_VERSION}-zip" \
#         "php${PHP_VERSION}-gd" \
#         "php${PHP_VERSION}-bcmath" \
#         "php${PHP_VERSION}-intl"
# else
#     echo "PHP ${PHP_VERSION} already installed."
# fi


# # ============================================================
# # PHP CLI / FPM defaults
# # ============================================================

# echo "==> Checking PHP ${PHP_VERSION}..."

# php${PHP_VERSION} -v

# systemctl enable --now "php${PHP_VERSION}-fpm"


# # ============================================================
# # Composer
# # ============================================================

# echo "==> Checking Composer..."

# if ! command -v composer >/dev/null 2>&1; then

#     echo "==> Installing Composer..."

#     EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)"

#     curl -fsSL https://getcomposer.org/installer \
#         -o /tmp/composer-setup.php

#     ACTUAL_SIGNATURE="$(
#         php${PHP_VERSION} -r \
#         "echo hash_file('sha384', '/tmp/composer-setup.php');"
#     )"

#     if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
#         echo "ERROR: Composer installer signature verification failed."
#         rm -f /tmp/composer-setup.php
#         exit 1
#     fi

#     php${PHP_VERSION} /tmp/composer-setup.php \
#         --install-dir=/usr/local/bin \
#         --filename=composer

#     rm -f /tmp/composer-setup.php

#     chmod +x /usr/local/bin/composer
# else
#     echo "Composer already installed."
# fi

# composer --version


# # ============================================================
# # Node.js 18
# # ============================================================

# echo "==> Checking Node.js..."

# NODE_OK=false

# if command -v node >/dev/null 2>&1; then

#     INSTALLED_NODE_MAJOR="$(
#         node -p "process.versions.node.split('.')[0]"
#     )"

#     if [ "$INSTALLED_NODE_MAJOR" = "$NODE_MAJOR" ]; then
#         NODE_OK=true
#         echo "Node.js ${NODE_MAJOR} already installed."
#     fi
# fi

# if [ "$NODE_OK" = false ]; then

#     echo "==> Installing Node.js ${NODE_MAJOR}..."

#     curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x \
#         | bash -

#     apt-get install -y nodejs
# fi

# echo "Node.js:"
# node --version

# echo "npm:"
# npm --version


# # ============================================================
# # MySQL (robust, self-healing install)
# # ============================================================

# echo "==> Checking MySQL..."

# install_mysql() {
#     echo "==> Installing MySQL Server..."
#     apt-get install -y mysql-server
#     systemctl daemon-reload
# }

# MYSQL_STATUS="$(dpkg-query -W -f='${Status}' mysql-server 2>/dev/null || true)"

# if ! echo "$MYSQL_STATUS" | grep -q "install ok installed"; then
#     install_mysql
# else
#     echo "MySQL Server package already installed."
# fi

# # If the package claims to be installed but systemd doesn't know
# # about the service (broken/partial install from an earlier run,
# # e.g. interrupted by a network blip), force a clean reinstall.
# if ! systemctl list-unit-files 2>/dev/null | grep -q '^mysql.service'; then
#     echo "mysql.service not found - package is in a broken state."
#     echo "==> Repairing dpkg state and reinstalling mysql-server..."

#     dpkg --configure -a || true
#     apt-get install -y --reinstall mysql-server
#     systemctl daemon-reload
# fi

# # Final check - if it's still missing, fail loudly with diagnostics
# # instead of silently continuing.
# if ! systemctl list-unit-files 2>/dev/null | grep -q '^mysql.service'; then
#     echo "ERROR: mysql.service still not found after reinstall attempt."
#     echo "---- diagnostics ----"
#     dpkg -l | grep -i mysql || true
#     echo "----------------------"
#     echo "Check manually: journalctl -u mysql --no-pager | tail -n 50"
#     echo "Check manually: cat /var/log/mysql/error.log"
#     exit 1
# fi

# systemctl enable --now mysql

# # Wait for MySQL to actually accept connections before configuring it
# echo "==> Waiting for MySQL to become ready..."
# for i in $(seq 1 30); do
#     if mysqladmin --protocol=socket ping >/dev/null 2>&1; then
#         echo "MySQL is ready."
#         break
#     fi
#     if [ "$i" -eq 30 ]; then
#         echo "ERROR: MySQL did not become ready in time."
#         systemctl status mysql --no-pager || true
#         exit 1
#     fi
#     sleep 1
# done

# echo "MySQL:"
# mysql --version

# echo "MySQL service:"
# systemctl is-active mysql


# # ============================================================
# # Create application database and user
# # ============================================================

# echo "==> Ensuring MySQL database exists..."

# mysql --protocol=socket -uroot <<MYSQL
# CREATE DATABASE IF NOT EXISTS ${DB_NAME}
#     CHARACTER SET utf8mb4
#     COLLATE utf8mb4_unicode_ci;

# CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost'
#     IDENTIFIED BY '${DB_PASSWORD}';

# ALTER USER '${DB_USER}'@'localhost'
#     IDENTIFIED BY '${DB_PASSWORD}';

# GRANT ALL PRIVILEGES
#     ON ${DB_NAME}.*
#     TO '${DB_USER}'@'localhost';

# FLUSH PRIVILEGES;
# MYSQL

# echo "Database: ${DB_NAME}"
# echo "User:     ${DB_USER}"


# # ============================================================
# # Nginx
# # ============================================================

# echo "==> Checking Nginx..."

# if ! command -v nginx >/dev/null 2>&1; then

#     echo "==> Installing Nginx..."

#     apt-get install -y nginx
# fi


# # ============================================================
# # Disable Apache if present
# # ============================================================

# if systemctl list-unit-files 2>/dev/null | grep -q '^apache2.service'; then

#     echo "==> Apache detected."

#     systemctl stop apache2 2>/dev/null || true
#     systemctl disable apache2 2>/dev/null || true

# fi


# # ============================================================
# # Create deployment directories
# # ============================================================

# echo "==> Creating deployment directories..."

# mkdir -p \
#     "${DEPLOY_PATH}" \
#     "${RELEASES_PATH}" \
#     "${SHARED_PATH}" \
#     "${SHARED_PATH}/storage" \
#     "${SHARED_PATH}/storage/app" \
#     "${SHARED_PATH}/storage/framework" \
#     "${SHARED_PATH}/storage/framework/cache" \
#     "${SHARED_PATH}/storage/framework/sessions" \
#     "${SHARED_PATH}/storage/framework/views" \
#     "${SHARED_PATH}/storage/logs"


# # ============================================================
# # Permissions
# # ============================================================

# echo "==> Setting deployment permissions..."

# chown -R "${DEPLOY_USER}:www-data" "${DEPLOY_PATH}"

# find "${DEPLOY_PATH}" \
#     -type d \
#     -exec chmod 775 {} \;

# find "${DEPLOY_PATH}" \
#     -type f \
#     -exec chmod 664 {} \;


# # ============================================================
# # Nginx configuration
# # ============================================================

# echo "==> Writing Nginx configuration..."

# cat > "${NGINX_CONF}" <<EOF
# server {
#     listen 80 default_server;
#     listen [::]:80 default_server;

#     server_name ${APP_DOMAIN} _;

#     root ${CURRENT_PATH}/public;

#     index index.php index.html;

#     charset utf-8;

#     add_header X-Frame-Options "SAMEORIGIN" always;
#     add_header X-Content-Type-Options "nosniff" always;
#     add_header Referrer-Policy "strict-origin-when-cross-origin" always;

#     location / {
#         try_files \$uri \$uri/ /index.php?\$query_string;
#     }

#     location = /favicon.ico {
#         access_log off;
#         log_not_found off;
#     }

#     location = /robots.txt {
#         access_log off;
#         log_not_found off;
#     }

#     location ~ \.php$ {
#         try_files \$uri =404;

#         include fastcgi_params;

#         fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
#         fastcgi_param DOCUMENT_ROOT \$realpath_root;

#         fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;

#         fastcgi_index index.php;

#         fastcgi_read_timeout 120;
#     }

#     location ~ /\.(?!well-known).* {
#         deny all;
#     }
# }
# EOF


# # ============================================================
# # Enable Nginx site
# # ============================================================

# ln -sfn "${NGINX_CONF}" "${NGINX_LINK}"

# rm -f /etc/nginx/sites-enabled/default


# # ============================================================
# # Test Nginx
# # ============================================================

# echo "==> Testing Nginx configuration..."

# nginx -t


# # ============================================================
# # Enable services
# # ============================================================

# echo "==> Enabling services..."

# systemctl enable --now nginx
# systemctl enable --now "php${PHP_VERSION}-fpm"


# # ============================================================
# # Final permissions
# # ============================================================

# echo "==> Applying final permissions..."

# chown -R "${DEPLOY_USER}:www-data" "${DEPLOY_PATH}"

# chmod 775 "${DEPLOY_PATH}"
# chmod 775 "${RELEASES_PATH}"
# chmod 775 "${SHARED_PATH}"
# chmod 775 "${SHARED_PATH}/storage"


# # ============================================================
# # Reload services
# # ============================================================

# echo "==> Reloading PHP-FPM..."

# systemctl reload "php${PHP_VERSION}-fpm"

# echo "==> Reloading Nginx..."

# systemctl reload nginx


# # ============================================================
# # Final verification
# # ============================================================

# echo
# echo "============================================================"
# echo " Provisioning completed successfully"
# echo "============================================================"

# echo
# echo "Deployment user: ${DEPLOY_USER}"

# echo
# echo "PHP:"
# php${PHP_VERSION} -v | head -n 1

# echo
# echo "Composer:"
# composer --version

# echo
# echo "Node:"
# node --version

# echo
# echo "npm:"
# npm --version

# echo
# echo "MySQL:"
# systemctl is-active mysql

# echo
# echo "PHP-FPM:"
# systemctl is-active "php${PHP_VERSION}-fpm"

# echo
# echo "Nginx:"
# systemctl is-active nginx

# echo
# echo "Deployment directories:"
# ls -ld \
#     "${DEPLOY_PATH}" \
#     "${RELEASES_PATH}" \
#     "${SHARED_PATH}"

# echo
# echo "============================================================"
# echo " Worker is ready for Forum Pipe deployment"
# echo "============================================================"










# # #!/bin/bash

# # # ============================================================
# # # Forum Pipe - Worker Provisioning (idempotent, safe to re-run)
# # # OS: Ubuntu 24.04 / 22.04
# # # Deployment: Non-Docker
# # # Web: Nginx
# # # PHP: 8.1
# # # Node.js: 18
# # # Database: MySQL 8
# # # ============================================================

# # set -euo pipefail

# # PHP_VERSION="8.1"
# # NODE_MAJOR="18"

# # APP_NAME="Forum Pipe"
# # APP_DOMAIN="forum.local"

# # DEPLOY_PATH="/var/www/forum-pipe"
# # RELEASES_PATH="${DEPLOY_PATH}/releases"
# # SHARED_PATH="${DEPLOY_PATH}/shared"
# # CURRENT_PATH="${DEPLOY_PATH}/current"

# # DB_NAME="forum"
# # DB_USER="forum_user"
# # DB_PASSWORD="forum_password"

# # NGINX_CONF="/etc/nginx/sites-available/forum-pipe"
# # NGINX_LINK="/etc/nginx/sites-enabled/forum-pipe"

# # echo
# # echo "============================================================"
# # echo " Forum Pipe - Worker Provisioning"
# # echo "============================================================"
# # echo " Host:          $(hostname)"
# # echo " PHP:           ${PHP_VERSION}"
# # echo " Node.js:       ${NODE_MAJOR}"
# # echo " Deploy path:   ${DEPLOY_PATH}"
# # echo "============================================================"
# # echo


# # # ============================================================
# # # Root check
# # # ============================================================

# # if [ "$(id -u)" -ne 0 ]; then
# #     echo "ERROR: This script must run as root."
# #     echo "Use: sudo bash deploy/provision-worker.sh"
# #     exit 1
# # fi


# # # ============================================================
# # # Deployment user
# # # ============================================================

# # if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
# #     DEPLOY_USER="${SUDO_USER}"
# # else
# #     DEPLOY_USER="$(stat -c '%U' /opt/actions-runner 2>/dev/null || true)"
# # fi

# # if [ -z "${DEPLOY_USER}" ] || [ "${DEPLOY_USER}" = "root" ]; then
# #     echo "ERROR: Could not determine deployment user."
# #     echo "This script should be executed through sudo by the GitHub Actions runner user."
# #     exit 1
# # fi

# # if ! id "${DEPLOY_USER}" >/dev/null 2>&1; then
# #     echo "ERROR: Deployment user '${DEPLOY_USER}' does not exist."
# #     exit 1
# # fi

# # echo "Deployment user: ${DEPLOY_USER}"


# # # ============================================================
# # # Fix any broken/interrupted dpkg state before doing anything
# # # ============================================================

# # echo "==> Ensuring dpkg is in a clean state..."
# # dpkg --configure -a || true


# # # ============================================================
# # # Remove stray/broken third-party repos that can break apt update
# # # ============================================================
# # #
# # # Some base images ship with unrelated repos (e.g. HashiCorp,
# # # added by a previous provisioning tool or manual setup) whose
# # # signing key is missing. This does not stop apt-get update from
# # # working overall, but it prints noisy errors and can eventually
# # # cause hard failures. We only touch it if it exists and is broken.
# # # ============================================================

# # if [ -f /etc/apt/sources.list.d/hashicorp.list ]; then
# #     if ! apt-key list 2>/dev/null | grep -qi "hashicorp"; then
# #         echo "==> Removing unreachable HashiCorp apt source (missing key)..."
# #         rm -f /etc/apt/sources.list.d/hashicorp.list
# #     fi
# # fi


# # # ============================================================
# # # APT prerequisites
# # # ============================================================

# # echo "==> Installing base packages..."

# # export DEBIAN_FRONTEND=noninteractive

# # apt-get update

# # apt-get install -y \
# #     ca-certificates \
# #     curl \
# #     wget \
# #     gnupg \
# #     dirmngr \
# #     lsb-release \
# #     apt-transport-https \
# #     software-properties-common \
# #     unzip \
# #     rsync \
# #     git \
# #     build-essential


# # # ============================================================
# # # PHP 8.1 repository
# # # ============================================================

# # echo "==> Checking PHP ${PHP_VERSION} repository..."

# # if ! command -v "php${PHP_VERSION}" >/dev/null 2>&1; then

# #     mkdir -p /etc/apt/keyrings

# #     if [ ! -f /etc/apt/keyrings/ondrej-php.gpg ]; then
# #         echo "==> Adding Ondrej PHP repository key..."

# #         gpg \
# #             --no-default-keyring \
# #             --keyring /etc/apt/keyrings/ondrej-php.gpg \
# #             --keyserver hkp://keyserver.ubuntu.com:80 \
# #             --recv-keys \
# #             4F4EA0AAE5267A6C \
# #             71DAEAAB4AD4CAB6
# #     fi

# #     if [ ! -f /etc/apt/sources.list.d/ondrej-php.list ]; then

# #         echo "deb [signed-by=/etc/apt/keyrings/ondrej-php.gpg] https://ppa.launchpadcontent.net/ondrej/php/ubuntu $(lsb_release -cs) main" \
# #             > /etc/apt/sources.list.d/ondrej-php.list
# #     fi

# #     apt-get update

# #     echo "==> Installing PHP ${PHP_VERSION}..."

# #     apt-get install -y \
# #         "php${PHP_VERSION}" \
# #         "php${PHP_VERSION}-cli" \
# #         "php${PHP_VERSION}-common" \
# #         "php${PHP_VERSION}-fpm" \
# #         "php${PHP_VERSION}-mysql" \
# #         "php${PHP_VERSION}-mbstring" \
# #         "php${PHP_VERSION}-xml" \
# #         "php${PHP_VERSION}-curl" \
# #         "php${PHP_VERSION}-zip" \
# #         "php${PHP_VERSION}-gd" \
# #         "php${PHP_VERSION}-bcmath" \
# #         "php${PHP_VERSION}-intl"
# # else
# #     echo "PHP ${PHP_VERSION} already installed."
# # fi


# # # ============================================================
# # # PHP CLI / FPM defaults
# # # ============================================================

# # echo "==> Checking PHP ${PHP_VERSION}..."

# # php${PHP_VERSION} -v

# # systemctl enable --now "php${PHP_VERSION}-fpm"


# # # ============================================================
# # # Composer
# # # ============================================================

# # echo "==> Checking Composer..."

# # if ! command -v composer >/dev/null 2>&1; then

# #     echo "==> Installing Composer..."

# #     EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)"

# #     curl -fsSL https://getcomposer.org/installer \
# #         -o /tmp/composer-setup.php

# #     ACTUAL_SIGNATURE="$(
# #         php${PHP_VERSION} -r \
# #         "echo hash_file('sha384', '/tmp/composer-setup.php');"
# #     )"

# #     if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
# #         echo "ERROR: Composer installer signature verification failed."
# #         rm -f /tmp/composer-setup.php
# #         exit 1
# #     fi

# #     php${PHP_VERSION} /tmp/composer-setup.php \
# #         --install-dir=/usr/local/bin \
# #         --filename=composer

# #     rm -f /tmp/composer-setup.php

# #     chmod +x /usr/local/bin/composer
# # else
# #     echo "Composer already installed."
# # fi

# # composer --version


# # # ============================================================
# # # Node.js 18
# # # ============================================================

# # echo "==> Checking Node.js..."

# # NODE_OK=false

# # if command -v node >/dev/null 2>&1; then

# #     INSTALLED_NODE_MAJOR="$(
# #         node -p "process.versions.node.split('.')[0]"
# #     )"

# #     if [ "$INSTALLED_NODE_MAJOR" = "$NODE_MAJOR" ]; then
# #         NODE_OK=true
# #         echo "Node.js ${NODE_MAJOR} already installed."
# #     fi
# # fi

# # if [ "$NODE_OK" = false ]; then

# #     echo "==> Installing Node.js ${NODE_MAJOR}..."

# #     curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x \
# #         | bash -

# #     apt-get install -y nodejs
# # fi

# # echo "Node.js:"
# # node --version

# # echo "npm:"
# # npm --version


# # # ============================================================
# # # MySQL (robust, self-healing install)
# # # ============================================================

# # echo "==> Checking MySQL..."

# # install_mysql() {
# #     echo "==> Installing MySQL Server..."
# #     apt-get install -y mysql-server
# #     systemctl daemon-reload
# # }

# # MYSQL_STATUS="$(dpkg-query -W -f='${Status}' mysql-server 2>/dev/null || true)"

# # if ! echo "$MYSQL_STATUS" | grep -q "install ok installed"; then
# #     install_mysql
# # else
# #     echo "MySQL Server package already installed."
# # fi

# # # If the package claims to be installed but systemd doesn't know
# # # about the service (broken/partial install from an earlier run,
# # # e.g. interrupted by a network blip), force a clean reinstall.
# # if ! systemctl list-unit-files 2>/dev/null | grep -q '^mysql.service'; then
# #     echo "mysql.service not found - package is in a broken state."
# #     echo "==> Repairing dpkg state and reinstalling mysql-server..."

# #     dpkg --configure -a || true
# #     apt-get install -y --reinstall mysql-server
# #     systemctl daemon-reload
# # fi

# # # Final check - if it's still missing, fail loudly with diagnostics
# # # instead of silently continuing.
# # if ! systemctl list-unit-files 2>/dev/null | grep -q '^mysql.service'; then
# #     echo "ERROR: mysql.service still not found after reinstall attempt."
# #     echo "---- diagnostics ----"
# #     dpkg -l | grep -i mysql || true
# #     echo "----------------------"
# #     echo "Check manually: journalctl -u mysql --no-pager | tail -n 50"
# #     echo "Check manually: cat /var/log/mysql/error.log"
# #     exit 1
# # fi

# # systemctl enable --now mysql

# # # Wait for MySQL to actually accept connections before configuring it
# # echo "==> Waiting for MySQL to become ready..."
# # for i in $(seq 1 30); do
# #     if mysqladmin --protocol=socket ping >/dev/null 2>&1; then
# #         echo "MySQL is ready."
# #         break
# #     fi
# #     if [ "$i" -eq 30 ]; then
# #         echo "ERROR: MySQL did not become ready in time."
# #         systemctl status mysql --no-pager || true
# #         exit 1
# #     fi
# #     sleep 1
# # done

# # echo "MySQL:"
# # mysql --version

# # echo "MySQL service:"
# # systemctl is-active mysql


# # # ============================================================
# # # Create application database and user
# # # ============================================================

# # echo "==> Ensuring MySQL database exists..."

# # mysql --protocol=socket -uroot <<MYSQL
# # CREATE DATABASE IF NOT EXISTS ${DB_NAME}
# #     CHARACTER SET utf8mb4
# #     COLLATE utf8mb4_unicode_ci;

# # CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost'
# #     IDENTIFIED BY '${DB_PASSWORD}';

# # ALTER USER '${DB_USER}'@'localhost'
# #     IDENTIFIED BY '${DB_PASSWORD}';

# # GRANT ALL PRIVILEGES
# #     ON ${DB_NAME}.*
# #     TO '${DB_USER}'@'localhost';

# # FLUSH PRIVILEGES;
# # MYSQL

# # echo "Database: ${DB_NAME}"
# # echo "User:     ${DB_USER}"


# # # ============================================================
# # # Nginx
# # # ============================================================

# # echo "==> Checking Nginx..."

# # if ! command -v nginx >/dev/null 2>&1; then

# #     echo "==> Installing Nginx..."

# #     apt-get install -y nginx
# # fi


# # # ============================================================
# # # Disable Apache if present
# # # ============================================================

# # if systemctl list-unit-files 2>/dev/null | grep -q '^apache2.service'; then

# #     echo "==> Apache detected."

# #     systemctl stop apache2 2>/dev/null || true
# #     systemctl disable apache2 2>/dev/null || true

# # fi


# # # ============================================================
# # # Create deployment directories
# # # ============================================================

# # echo "==> Creating deployment directories..."

# # mkdir -p \
# #     "${DEPLOY_PATH}" \
# #     "${RELEASES_PATH}" \
# #     "${SHARED_PATH}" \
# #     "${SHARED_PATH}/storage" \
# #     "${SHARED_PATH}/storage/app" \
# #     "${SHARED_PATH}/storage/framework" \
# #     "${SHARED_PATH}/storage/framework/cache" \
# #     "${SHARED_PATH}/storage/framework/sessions" \
# #     "${SHARED_PATH}/storage/framework/views" \
# #     "${SHARED_PATH}/storage/logs"


# # # ============================================================
# # # Permissions
# # # ============================================================

# # echo "==> Setting deployment permissions..."

# # chown -R "${DEPLOY_USER}:www-data" "${DEPLOY_PATH}"

# # find "${DEPLOY_PATH}" \
# #     -type d \
# #     -exec chmod 775 {} \;

# # find "${DEPLOY_PATH}" \
# #     -type f \
# #     -exec chmod 664 {} \;


# # # ============================================================
# # # Nginx configuration
# # # ============================================================

# # echo "==> Writing Nginx configuration..."

# # cat > "${NGINX_CONF}" <<EOF
# # server {
# #     listen 80 default_server;
# #     listen [::]:80 default_server;

# #     server_name ${APP_DOMAIN} _;

# #     root ${CURRENT_PATH}/public;

# #     index index.php index.html;

# #     charset utf-8;

# #     add_header X-Frame-Options "SAMEORIGIN" always;
# #     add_header X-Content-Type-Options "nosniff" always;
# #     add_header Referrer-Policy "strict-origin-when-cross-origin" always;

# #     location / {
# #         try_files \$uri \$uri/ /index.php?\$query_string;
# #     }

# #     location = /favicon.ico {
# #         access_log off;
# #         log_not_found off;
# #     }

# #     location = /robots.txt {
# #         access_log off;
# #         log_not_found off;
# #     }

# #     location ~ \.php$ {
# #         try_files \$uri =404;

# #         include fastcgi_params;

# #         fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
# #         fastcgi_param DOCUMENT_ROOT \$realpath_root;

# #         fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;

# #         fastcgi_index index.php;

# #         fastcgi_read_timeout 120;
# #     }

# #     location ~ /\.(?!well-known).* {
# #         deny all;
# #     }
# # }
# # EOF


# # # ============================================================
# # # Enable Nginx site
# # # ============================================================

# # ln -sfn "${NGINX_CONF}" "${NGINX_LINK}"

# # rm -f /etc/nginx/sites-enabled/default


# # # ============================================================
# # # Test Nginx
# # # ============================================================

# # echo "==> Testing Nginx configuration..."

# # nginx -t


# # # ============================================================
# # # Enable services
# # # ============================================================

# # echo "==> Enabling services..."

# # systemctl enable --now nginx
# # systemctl enable --now "php${PHP_VERSION}-fpm"


# # # ============================================================
# # # Final permissions
# # # ============================================================

# # echo "==> Applying final permissions..."

# # chown -R "${DEPLOY_USER}:www-data" "${DEPLOY_PATH}"

# # chmod 775 "${DEPLOY_PATH}"
# # chmod 775 "${RELEASES_PATH}"
# # chmod 775 "${SHARED_PATH}"
# # chmod 775 "${SHARED_PATH}/storage"


# # # ============================================================
# # # Reload services
# # # ============================================================

# # echo "==> Reloading PHP-FPM..."

# # systemctl reload "php${PHP_VERSION}-fpm"

# # echo "==> Reloading Nginx..."

# # systemctl reload nginx


# # # ============================================================
# # # Final verification
# # # ============================================================

# # echo
# # echo "============================================================"
# # echo " Provisioning completed successfully"
# # echo "============================================================"

# # echo
# # echo "Deployment user: ${DEPLOY_USER}"

# # echo
# # echo "PHP:"
# # php${PHP_VERSION} -v | head -n 1

# # echo
# # echo "Composer:"
# # composer --version

# # echo
# # echo "Node:"
# # node --version

# # echo
# # echo "npm:"
# # npm --version

# # echo
# # echo "MySQL:"
# # systemctl is-active mysql

# # echo
# # echo "PHP-FPM:"
# # systemctl is-active "php${PHP_VERSION}-fpm"

# # echo
# # echo "Nginx:"
# # systemctl is-active nginx

# # echo
# # echo "Deployment directories:"
# # ls -ld \
# #     "${DEPLOY_PATH}" \
# #     "${RELEASES_PATH}" \
# #     "${SHARED_PATH}"

# # echo
# # echo "============================================================"
# # echo " Worker is ready for Forum Pipe deployment"
# # echo "============================================================"








# # # #!/bin/bash

# # # # ============================================================
# # # # Forum Pipe - Worker Provisioning
# # # # Target: worker01
# # # # OS: Ubuntu 24.04
# # # # Deployment: Non-Docker
# # # # Web: Nginx
# # # # PHP: 8.1
# # # # Node.js: 18
# # # # Database: MySQL 8
# # # # ============================================================

# # # set -euo pipefail

# # # PHP_VERSION="8.1"
# # # NODE_MAJOR="18"

# # # APP_NAME="Forum Pipe"
# # # APP_DOMAIN="forum.local"

# # # DEPLOY_PATH="/var/www/forum-pipe"
# # # RELEASES_PATH="${DEPLOY_PATH}/releases"
# # # SHARED_PATH="${DEPLOY_PATH}/shared"
# # # CURRENT_PATH="${DEPLOY_PATH}/current"

# # # DB_NAME="forum"
# # # DB_USER="forum_user"
# # # DB_PASSWORD="forum_password"

# # # NGINX_CONF="/etc/nginx/sites-available/forum-pipe"
# # # NGINX_LINK="/etc/nginx/sites-enabled/forum-pipe"

# # # echo
# # # echo "============================================================"
# # # echo " Forum Pipe - Worker Provisioning"
# # # echo "============================================================"
# # # echo " Host:          $(hostname)"
# # # echo " PHP:           ${PHP_VERSION}"
# # # echo " Node.js:       ${NODE_MAJOR}"
# # # echo " Deploy path:   ${DEPLOY_PATH}"
# # # echo "============================================================"
# # # echo


# # # # ============================================================
# # # # Root check
# # # # ============================================================

# # # if [ "$(id -u)" -ne 0 ]; then
# # #     echo "ERROR: This script must run as root."
# # #     echo "Use: sudo bash deploy/provision-worker.sh"
# # #     exit 1
# # # fi


# # # # ============================================================
# # # # Deployment user
# # # # ============================================================

# # # # When GitHub Actions runs:
# # # #   nuruzzaman -> sudo bash deploy/provision-worker.sh
# # # #
# # # # SUDO_USER will therefore be the GitHub Actions runner user.
# # # # This avoids hard-coding a user such as "deployer".

# # # if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
# # #     DEPLOY_USER="${SUDO_USER}"
# # # else
# # #     DEPLOY_USER="$(stat -c '%U' /opt/actions-runner 2>/dev/null || true)"
# # # fi

# # # if [ -z "${DEPLOY_USER}" ] || [ "${DEPLOY_USER}" = "root" ]; then
# # #     echo "ERROR: Could not determine deployment user."
# # #     echo "This script should be executed through sudo by the GitHub Actions runner user."
# # #     exit 1
# # # fi

# # # if ! id "${DEPLOY_USER}" >/dev/null 2>&1; then
# # #     echo "ERROR: Deployment user '${DEPLOY_USER}' does not exist."
# # #     exit 1
# # # fi

# # # echo "Deployment user: ${DEPLOY_USER}"


# # # # ============================================================
# # # # APT prerequisites
# # # # ============================================================

# # # echo "==> Installing base packages..."

# # # export DEBIAN_FRONTEND=noninteractive

# # # apt-get update

# # # apt-get install -y \
# # #     ca-certificates \
# # #     curl \
# # #     wget \
# # #     gnupg \
# # #     dirmngr \
# # #     lsb-release \
# # #     apt-transport-https \
# # #     software-properties-common \
# # #     unzip \
# # #     rsync \
# # #     git \
# # #     build-essential


# # # # ============================================================
# # # # PHP 8.1 repository
# # # # ============================================================

# # # echo "==> Checking PHP ${PHP_VERSION} repository..."

# # # if ! command -v "php${PHP_VERSION}" >/dev/null 2>&1; then

# # #     mkdir -p /etc/apt/keyrings

# # #     if [ ! -f /etc/apt/keyrings/ondrej-php.gpg ]; then
# # #         echo "==> Adding Ondrej PHP repository key..."

# # #         gpg \
# # #             --no-default-keyring \
# # #             --keyring /etc/apt/keyrings/ondrej-php.gpg \
# # #             --keyserver hkp://keyserver.ubuntu.com:80 \
# # #             --recv-keys \
# # #             4F4EA0AAE5267A6C \
# # #             71DAEAAB4AD4CAB6
# # #     fi

# # #     if [ ! -f /etc/apt/sources.list.d/ondrej-php.list ]; then

# # #         echo "deb [signed-by=/etc/apt/keyrings/ondrej-php.gpg] https://ppa.launchpadcontent.net/ondrej/php/ubuntu $(lsb_release -cs) main" \
# # #             > /etc/apt/sources.list.d/ondrej-php.list
# # #     fi

# # #     apt-get update

# # #     echo "==> Installing PHP ${PHP_VERSION}..."

# # #     apt-get install -y \
# # #         "php${PHP_VERSION}" \
# # #         "php${PHP_VERSION}-cli" \
# # #         "php${PHP_VERSION}-common" \
# # #         "php${PHP_VERSION}-fpm" \
# # #         "php${PHP_VERSION}-mysql" \
# # #         "php${PHP_VERSION}-mbstring" \
# # #         "php${PHP_VERSION}-xml" \
# # #         "php${PHP_VERSION}-curl" \
# # #         "php${PHP_VERSION}-zip" \
# # #         "php${PHP_VERSION}-gd" \
# # #         "php${PHP_VERSION}-bcmath" \
# # #         "php${PHP_VERSION}-intl"
# # # else
# # #     echo "PHP ${PHP_VERSION} already installed."
# # # fi


# # # # ============================================================
# # # # PHP CLI / FPM defaults
# # # # ============================================================

# # # echo "==> Checking PHP ${PHP_VERSION}..."

# # # php${PHP_VERSION} -v

# # # systemctl enable --now "php${PHP_VERSION}-fpm"


# # # # ============================================================
# # # # Composer
# # # # ============================================================

# # # echo "==> Checking Composer..."

# # # if ! command -v composer >/dev/null 2>&1; then

# # #     echo "==> Installing Composer..."

# # #     EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)"

# # #     curl -fsSL https://getcomposer.org/installer \
# # #         -o /tmp/composer-setup.php

# # #     ACTUAL_SIGNATURE="$(
# # #         php${PHP_VERSION} -r \
# # #         "echo hash_file('sha384', '/tmp/composer-setup.php');"
# # #     )"

# # #     if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
# # #         echo "ERROR: Composer installer signature verification failed."
# # #         rm -f /tmp/composer-setup.php
# # #         exit 1
# # #     fi

# # #     php${PHP_VERSION} /tmp/composer-setup.php \
# # #         --install-dir=/usr/local/bin \
# # #         --filename=composer

# # #     rm -f /tmp/composer-setup.php

# # #     chmod +x /usr/local/bin/composer
# # # else
# # #     echo "Composer already installed."
# # # fi

# # # composer --version


# # # # ============================================================
# # # # Node.js 18
# # # # ============================================================

# # # echo "==> Checking Node.js..."

# # # NODE_OK=false

# # # if command -v node >/dev/null 2>&1; then

# # #     INSTALLED_NODE_MAJOR="$(
# # #         node -p "process.versions.node.split('.')[0]"
# # #     )"

# # #     if [ "$INSTALLED_NODE_MAJOR" = "$NODE_MAJOR" ]; then
# # #         NODE_OK=true
# # #         echo "Node.js ${NODE_MAJOR} already installed."
# # #     fi
# # # fi

# # # if [ "$NODE_OK" = false ]; then

# # #     echo "==> Installing Node.js ${NODE_MAJOR}..."

# # #     curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x \
# # #         | bash -

# # #     apt-get install -y nodejs
# # # fi

# # # echo "Node.js:"
# # # node --version

# # # echo "npm:"
# # # npm --version


# # # # ============================================================
# # # # MySQL
# # # # ============================================================

# # # # echo "==> Checking MySQL..."

# # # # if ! command -v mysql >/dev/null 2>&1; then
# # # #     echo "==> Installing MySQL..."

# # # #     apt-get install -y mysql-server
# # # # fi

# # # # systemctl enable --now mysql

# # # # echo "MySQL:"
# # # # mysql --version


# # # echo "==> Checking MySQL..."

# # # if ! dpkg-query -W -f='${Status}' mysql-server 2>/dev/null | grep -q "install ok installed"; then
# # #     echo "==> Installing MySQL Server..."
# # #     apt-get install -y mysql-server
# # # else
# # #     echo "MySQL Server package already installed."
# # # fi

# # # if ! systemctl list-unit-files 2>/dev/null | grep -q '^mysql.service'; then
# # #     echo "ERROR: mysql.service was not found after MySQL Server installation."
# # #     echo "MySQL Server installation did not complete correctly."
# # #     exit 1
# # # fi

# # # systemctl enable --now mysql

# # # echo "MySQL:"
# # # mysql --version

# # # echo "MySQL service:"
# # # systemctl is-active mysql






# # # # ============================================================
# # # # Create application database and user
# # # # ============================================================

# # # echo "==> Ensuring MySQL database exists..."

# # # mysql --protocol=socket -uroot <<MYSQL
# # # CREATE DATABASE IF NOT EXISTS ${DB_NAME}
# # #     CHARACTER SET utf8mb4
# # #     COLLATE utf8mb4_unicode_ci;

# # # CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost'
# # #     IDENTIFIED BY '${DB_PASSWORD}';

# # # ALTER USER '${DB_USER}'@'localhost'
# # #     IDENTIFIED BY '${DB_PASSWORD}';

# # # GRANT ALL PRIVILEGES
# # #     ON ${DB_NAME}.*
# # #     TO '${DB_USER}'@'localhost';

# # # FLUSH PRIVILEGES;
# # # MYSQL

# # # echo "Database: ${DB_NAME}"
# # # echo "User:     ${DB_USER}"


# # # # ============================================================
# # # # Nginx
# # # # ============================================================

# # # echo "==> Checking Nginx..."

# # # if ! command -v nginx >/dev/null 2>&1; then

# # #     echo "==> Installing Nginx..."

# # #     apt-get install -y nginx
# # # fi


# # # # ============================================================
# # # # Disable Apache if present
# # # # ============================================================

# # # if systemctl list-unit-files 2>/dev/null | grep -q '^apache2.service'; then

# # #     echo "==> Apache detected."

# # #     systemctl stop apache2 2>/dev/null || true
# # #     systemctl disable apache2 2>/dev/null || true

# # # fi


# # # # ============================================================
# # # # Create deployment directories
# # # # ============================================================

# # # echo "==> Creating deployment directories..."

# # # mkdir -p \
# # #     "${DEPLOY_PATH}" \
# # #     "${RELEASES_PATH}" \
# # #     "${SHARED_PATH}" \
# # #     "${SHARED_PATH}/storage" \
# # #     "${SHARED_PATH}/storage/app" \
# # #     "${SHARED_PATH}/storage/framework" \
# # #     "${SHARED_PATH}/storage/framework/cache" \
# # #     "${SHARED_PATH}/storage/framework/sessions" \
# # #     "${SHARED_PATH}/storage/framework/views" \
# # #     "${SHARED_PATH}/storage/logs"


# # # # ============================================================
# # # # Permissions
# # # # ============================================================

# # # echo "==> Setting deployment permissions..."

# # # chown -R "${DEPLOY_USER}:www-data" "${DEPLOY_PATH}"

# # # find "${DEPLOY_PATH}" \
# # #     -type d \
# # #     -exec chmod 775 {} \;

# # # find "${DEPLOY_PATH}" \
# # #     -type f \
# # #     -exec chmod 664 {} \;


# # # # ============================================================
# # # # Nginx configuration
# # # # ============================================================

# # # echo "==> Writing Nginx configuration..."

# # # cat > "${NGINX_CONF}" <<EOF
# # # server {
# # #     listen 80 default_server;
# # #     listen [::]:80 default_server;

# # #     server_name ${APP_DOMAIN} 172.17.0.232 _;

# # #     root ${CURRENT_PATH}/public;

# # #     index index.php index.html;

# # #     charset utf-8;

# # #     add_header X-Frame-Options "SAMEORIGIN" always;
# # #     add_header X-Content-Type-Options "nosniff" always;
# # #     add_header Referrer-Policy "strict-origin-when-cross-origin" always;

# # #     location / {
# # #         try_files \$uri \$uri/ /index.php?\$query_string;
# # #     }

# # #     location = /favicon.ico {
# # #         access_log off;
# # #         log_not_found off;
# # #     }

# # #     location = /robots.txt {
# # #         access_log off;
# # #         log_not_found off;
# # #     }

# # #     location ~ \.php$ {
# # #         try_files \$uri =404;

# # #         include fastcgi_params;

# # #         fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
# # #         fastcgi_param DOCUMENT_ROOT \$realpath_root;

# # #         fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;

# # #         fastcgi_index index.php;

# # #         fastcgi_read_timeout 120;
# # #     }

# # #     location ~ /\.(?!well-known).* {
# # #         deny all;
# # #     }
# # # }
# # # EOF


# # # # ============================================================
# # # # Enable Nginx site
# # # # ============================================================

# # # ln -sfn "${NGINX_CONF}" "${NGINX_LINK}"

# # # rm -f /etc/nginx/sites-enabled/default


# # # # ============================================================
# # # # Test Nginx
# # # # ============================================================

# # # echo "==> Testing Nginx configuration..."

# # # nginx -t


# # # # ============================================================
# # # # Enable services
# # # # ============================================================

# # # echo "==> Enabling services..."

# # # systemctl enable --now nginx
# # # systemctl enable --now "php${PHP_VERSION}-fpm"


# # # # ============================================================
# # # # Final permissions
# # # # ============================================================

# # # echo "==> Applying final permissions..."

# # # chown -R "${DEPLOY_USER}:www-data" "${DEPLOY_PATH}"

# # # chmod 775 "${DEPLOY_PATH}"
# # # chmod 775 "${RELEASES_PATH}"
# # # chmod 775 "${SHARED_PATH}"
# # # chmod 775 "${SHARED_PATH}/storage"


# # # # ============================================================
# # # # Reload services
# # # # ============================================================

# # # echo "==> Reloading PHP-FPM..."

# # # systemctl reload "php${PHP_VERSION}-fpm"

# # # echo "==> Reloading Nginx..."

# # # systemctl reload nginx


# # # # ============================================================
# # # # Final verification
# # # # ============================================================

# # # echo
# # # echo "============================================================"
# # # echo " Provisioning completed successfully"
# # # echo "============================================================"

# # # echo
# # # echo "Deployment user:"
# # # echo "${DEPLOY_USER}"

# # # echo
# # # echo "PHP:"
# # # php${PHP_VERSION} -v | head -n 1

# # # echo
# # # echo "Composer:"
# # # composer --version

# # # echo
# # # echo "Node:"
# # # node --version

# # # echo
# # # echo "npm:"
# # # npm --version

# # # echo
# # # echo "MySQL:"
# # # systemctl is-active mysql

# # # echo
# # # echo "PHP-FPM:"
# # # systemctl is-active "php${PHP_VERSION}-fpm"

# # # echo
# # # echo "Nginx:"
# # # systemctl is-active nginx

# # # echo
# # # echo "Deployment directories:"
# # # ls -ld \
# # #     "${DEPLOY_PATH}" \
# # #     "${RELEASES_PATH}" \
# # #     "${SHARED_PATH}"

# # # echo
# # # echo "============================================================"
# # # echo " Worker01 is ready for Forum Pipe deployment"
# # # echo "============================================================"







# # # # #!/bin/bash

# # # # # ============================================================
# # # # # Forum Pipe - Worker Provisioning
# # # # # Target: worker01
# # # # # OS: Ubuntu 24.04
# # # # # Deployment: Non-Docker
# # # # # Web: Nginx
# # # # # PHP: 8.1
# # # # # Node.js: 18
# # # # # Database: MySQL 8
# # # # # ============================================================

# # # # set -euo pipefail

# # # # PHP_VERSION="8.1"
# # # # NODE_MAJOR="18"

# # # # APP_NAME="Forum Pipe"
# # # # APP_DOMAIN="forum.local"

# # # # DEPLOY_PATH="/var/www/forum-pipe"
# # # # RELEASES_PATH="${DEPLOY_PATH}/releases"
# # # # SHARED_PATH="${DEPLOY_PATH}/shared"
# # # # CURRENT_PATH="${DEPLOY_PATH}/current"

# # # # DB_NAME="forum"
# # # # DB_USER="forum_user"
# # # # DB_PASSWORD="forum_password"

# # # # NGINX_CONF="/etc/nginx/sites-available/forum-pipe"
# # # # NGINX_LINK="/etc/nginx/sites-enabled/forum-pipe"

# # # # echo
# # # # echo "============================================================"
# # # # echo " Forum Pipe - Worker Provisioning"
# # # # echo "============================================================"
# # # # echo " Host:          $(hostname)"
# # # # echo " PHP:           ${PHP_VERSION}"
# # # # echo " Node.js:       ${NODE_MAJOR}"
# # # # echo " Deploy path:   ${DEPLOY_PATH}"
# # # # echo "============================================================"
# # # # echo


# # # # # ============================================================
# # # # # Root check
# # # # # ============================================================

# # # # if [ "$(id -u)" -ne 0 ]; then
# # # #     echo "ERROR: This script must run as root."
# # # #     echo "Use: sudo bash deploy/provision-worker.sh"
# # # #     exit 1
# # # # fi


# # # # # ============================================================
# # # # # Deployment user
# # # # # ============================================================

# # # # # When GitHub Actions runs:
# # # # #   nuruzzaman -> sudo bash deploy/provision-worker.sh
# # # # #
# # # # # SUDO_USER will therefore be the GitHub Actions runner user.
# # # # # This avoids hard-coding a user such as "deployer".

# # # # if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
# # # #     DEPLOY_USER="${SUDO_USER}"
# # # # else
# # # #     DEPLOY_USER="$(stat -c '%U' /opt/actions-runner 2>/dev/null || true)"
# # # # fi

# # # # if [ -z "${DEPLOY_USER}" ] || [ "${DEPLOY_USER}" = "root" ]; then
# # # #     echo "ERROR: Could not determine deployment user."
# # # #     echo "This script should be executed through sudo by the GitHub Actions runner user."
# # # #     exit 1
# # # # fi

# # # # if ! id "${DEPLOY_USER}" >/dev/null 2>&1; then
# # # #     echo "ERROR: Deployment user '${DEPLOY_USER}' does not exist."
# # # #     exit 1
# # # # fi

# # # # echo "Deployment user: ${DEPLOY_USER}"


# # # # # ============================================================
# # # # # APT prerequisites
# # # # # ============================================================

# # # # echo "==> Installing base packages..."

# # # # export DEBIAN_FRONTEND=noninteractive

# # # # apt-get update

# # # # apt-get install -y \
# # # #     ca-certificates \
# # # #     curl \
# # # #     wget \
# # # #     gnupg \
# # # #     dirmngr \
# # # #     lsb-release \
# # # #     apt-transport-https \
# # # #     software-properties-common \
# # # #     unzip \
# # # #     rsync \
# # # #     git \
# # # #     build-essential


# # # # # ============================================================
# # # # # PHP 8.1 repository
# # # # # ============================================================

# # # # echo "==> Checking PHP ${PHP_VERSION} repository..."

# # # # if ! command -v "php${PHP_VERSION}" >/dev/null 2>&1; then

# # # #     mkdir -p /etc/apt/keyrings

# # # #     if [ ! -f /etc/apt/keyrings/ondrej-php.gpg ]; then
# # # #         echo "==> Adding Ondrej PHP repository key..."

# # # #         gpg \
# # # #             --no-default-keyring \
# # # #             --keyring /etc/apt/keyrings/ondrej-php.gpg \
# # # #             --keyserver hkp://keyserver.ubuntu.com:80 \
# # # #             --recv-keys \
# # # #             4F4EA0AAE5267A6C \
# # # #             71DAEAAB4AD4CAB6
# # # #     fi

# # # #     if [ ! -f /etc/apt/sources.list.d/ondrej-php.list ]; then

# # # #         echo "deb [signed-by=/etc/apt/keyrings/ondrej-php.gpg] https://ppa.launchpadcontent.net/ondrej/php/ubuntu $(lsb_release -cs) main" \
# # # #             > /etc/apt/sources.list.d/ondrej-php.list
# # # #     fi

# # # #     apt-get update

# # # #     echo "==> Installing PHP ${PHP_VERSION}..."

# # # #     apt-get install -y \
# # # #         "php${PHP_VERSION}" \
# # # #         "php${PHP_VERSION}-cli" \
# # # #         "php${PHP_VERSION}-common" \
# # # #         "php${PHP_VERSION}-fpm" \
# # # #         "php${PHP_VERSION}-mysql" \
# # # #         "php${PHP_VERSION}-mbstring" \
# # # #         "php${PHP_VERSION}-xml" \
# # # #         "php${PHP_VERSION}-curl" \
# # # #         "php${PHP_VERSION}-zip" \
# # # #         "php${PHP_VERSION}-gd" \
# # # #         "php${PHP_VERSION}-bcmath" \
# # # #         "php${PHP_VERSION}-intl"
# # # # else
# # # #     echo "PHP ${PHP_VERSION} already installed."
# # # # fi


# # # # # ============================================================
# # # # # PHP CLI / FPM defaults
# # # # # ============================================================

# # # # echo "==> Checking PHP ${PHP_VERSION}..."

# # # # php${PHP_VERSION} -v

# # # # systemctl enable --now "php${PHP_VERSION}-fpm"


# # # # # ============================================================
# # # # # Composer
# # # # # ============================================================

# # # # echo "==> Checking Composer..."

# # # # if ! command -v composer >/dev/null 2>&1; then

# # # #     echo "==> Installing Composer..."

# # # #     EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)"

# # # #     curl -fsSL https://getcomposer.org/installer \
# # # #         -o /tmp/composer-setup.php

# # # #     ACTUAL_SIGNATURE="$(
# # # #         php${PHP_VERSION} -r \
# # # #         "echo hash_file('sha384', '/tmp/composer-setup.php');"
# # # #     )"

# # # #     if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
# # # #         echo "ERROR: Composer installer signature verification failed."
# # # #         rm -f /tmp/composer-setup.php
# # # #         exit 1
# # # #     fi

# # # #     php${PHP_VERSION} /tmp/composer-setup.php \
# # # #         --install-dir=/usr/local/bin \
# # # #         --filename=composer

# # # #     rm -f /tmp/composer-setup.php

# # # #     chmod +x /usr/local/bin/composer
# # # # else
# # # #     echo "Composer already installed."
# # # # fi

# # # # composer --version


# # # # # ============================================================
# # # # # Node.js 18
# # # # # ============================================================

# # # # echo "==> Checking Node.js..."

# # # # NODE_OK=false

# # # # if command -v node >/dev/null 2>&1; then

# # # #     INSTALLED_NODE_MAJOR="$(
# # # #         node -p "process.versions.node.split('.')[0]"
# # # #     )"

# # # #     if [ "$INSTALLED_NODE_MAJOR" = "$NODE_MAJOR" ]; then
# # # #         NODE_OK=true
# # # #         echo "Node.js ${NODE_MAJOR} already installed."
# # # #     fi
# # # # fi

# # # # if [ "$NODE_OK" = false ]; then

# # # #     echo "==> Installing Node.js ${NODE_MAJOR}..."

# # # #     curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x \
# # # #         | bash -

# # # #     apt-get install -y nodejs
# # # # fi

# # # # echo "Node.js:"
# # # # node --version

# # # # echo "npm:"
# # # # npm --version


# # # # # ============================================================
# # # # # MySQL
# # # # # ============================================================

# # # # echo "==> Checking MySQL..."

# # # # if ! command -v mysql >/dev/null 2>&1; then
# # # #     echo "==> Installing MySQL..."

# # # #     apt-get install -y mysql-server
# # # # fi

# # # # systemctl enable --now mysql

# # # # echo "MySQL:"
# # # # mysql --version


# # # # # ============================================================
# # # # # Create application database and user
# # # # # ============================================================

# # # # echo "==> Ensuring MySQL database exists..."

# # # # mysql --protocol=socket -uroot <<MYSQL
# # # # CREATE DATABASE IF NOT EXISTS ${DB_NAME}
# # # #     CHARACTER SET utf8mb4
# # # #     COLLATE utf8mb4_unicode_ci;

# # # # CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost'
# # # #     IDENTIFIED BY '${DB_PASSWORD}';

# # # # ALTER USER '${DB_USER}'@'localhost'
# # # #     IDENTIFIED BY '${DB_PASSWORD}';

# # # # GRANT ALL PRIVILEGES
# # # #     ON ${DB_NAME}.*
# # # #     TO '${DB_USER}'@'localhost';

# # # # FLUSH PRIVILEGES;
# # # # MYSQL

# # # # echo "Database: ${DB_NAME}"
# # # # echo "User:     ${DB_USER}"


# # # # # ============================================================
# # # # # Nginx
# # # # # ============================================================

# # # # echo "==> Checking Nginx..."

# # # # if ! command -v nginx >/dev/null 2>&1; then

# # # #     echo "==> Installing Nginx..."

# # # #     apt-get install -y nginx
# # # # fi


# # # # # ============================================================
# # # # # Disable Apache if present
# # # # # ============================================================

# # # # if systemctl list-unit-files 2>/dev/null | grep -q '^apache2.service'; then

# # # #     echo "==> Apache detected."

# # # #     systemctl stop apache2 2>/dev/null || true
# # # #     systemctl disable apache2 2>/dev/null || true

# # # # fi


# # # # # ============================================================
# # # # # Create deployment directories
# # # # # ============================================================

# # # # echo "==> Creating deployment directories..."

# # # # mkdir -p \
# # # #     "${DEPLOY_PATH}" \
# # # #     "${RELEASES_PATH}" \
# # # #     "${SHARED_PATH}" \
# # # #     "${SHARED_PATH}/storage" \
# # # #     "${SHARED_PATH}/storage/app" \
# # # #     "${SHARED_PATH}/storage/framework" \
# # # #     "${SHARED_PATH}/storage/framework/cache" \
# # # #     "${SHARED_PATH}/storage/framework/sessions" \
# # # #     "${SHARED_PATH}/storage/framework/views" \
# # # #     "${SHARED_PATH}/storage/logs"


# # # # # ============================================================
# # # # # Permissions
# # # # # ============================================================

# # # # echo "==> Setting deployment permissions..."

# # # # chown -R "${DEPLOY_USER}:www-data" "${DEPLOY_PATH}"

# # # # find "${DEPLOY_PATH}" \
# # # #     -type d \
# # # #     -exec chmod 775 {} \;

# # # # find "${DEPLOY_PATH}" \
# # # #     -type f \
# # # #     -exec chmod 664 {} \;


# # # # # ============================================================
# # # # # Nginx configuration
# # # # # ============================================================

# # # # echo "==> Writing Nginx configuration..."

# # # # cat > "${NGINX_CONF}" <<EOF
# # # # server {
# # # #     listen 80 default_server;
# # # #     listen [::]:80 default_server;

# # # #     server_name ${APP_DOMAIN} 172.17.0.232 _;

# # # #     root ${CURRENT_PATH}/public;

# # # #     index index.php index.html;

# # # #     charset utf-8;

# # # #     add_header X-Frame-Options "SAMEORIGIN" always;
# # # #     add_header X-Content-Type-Options "nosniff" always;
# # # #     add_header Referrer-Policy "strict-origin-when-cross-origin" always;

# # # #     location / {
# # # #         try_files \$uri \$uri/ /index.php?\$query_string;
# # # #     }

# # # #     location = /favicon.ico {
# # # #         access_log off;
# # # #         log_not_found off;
# # # #     }

# # # #     location = /robots.txt {
# # # #         access_log off;
# # # #         log_not_found off;
# # # #     }

# # # #     location ~ \.php$ {
# # # #         try_files \$uri =404;

# # # #         include fastcgi_params;

# # # #         fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
# # # #         fastcgi_param DOCUMENT_ROOT \$realpath_root;

# # # #         fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;

# # # #         fastcgi_index index.php;

# # # #         fastcgi_read_timeout 120;
# # # #     }

# # # #     location ~ /\.(?!well-known).* {
# # # #         deny all;
# # # #     }
# # # # }
