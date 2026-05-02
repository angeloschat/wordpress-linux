#!/usr/bin/env bash

set -Eeuo pipefail

trap 'echo "Error on line $LINENO. Installation aborted." >&2' ERR

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Please run this script as root." >&2
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

validate_domain() {
  local domain="$1"
  [[ "$domain" =~ ^([A-Za-z0-9](-?[A-Za-z0-9])*)(\.([A-Za-z0-9](-?[A-Za-z0-9])*))+\.?$ ]]
}

sanitize_identifier() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '_' | sed 's/^_*//; s/_*$//'
}

random_password() {
  LC_ALL=C tr -dc 'A-Za-z0-9@#%_=+.-' < /dev/urandom | head -c 32
  echo
}

prompt_secret() {
  local prompt="$1"
  local var_name="$2"
  local value
  read -rsp "$prompt: " value
  echo
  if [[ -z "$value" ]]; then
    echo "Error: value cannot be empty." >&2
    exit 1
  fi
  printf -v "$var_name" '%s' "$value"
}

fetch_wp_salts() {
  curl -fsSL https://api.wordpress.org/secret-key/1.1/salt/
}

run_wp() {
  local wp_path="$1"
  shift
  runuser -u www-data -- wp --path="$wp_path" "$@"
}

create_db_and_user() {
  local db_name="$1"
  local db_user="$2"
  local db_password="$3"

  mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_password}';
ALTER USER '${db_user}'@'localhost' IDENTIFIED BY '${db_password}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';
FLUSH PRIVILEGES;
SQL
}

write_apache_vhost() {
  local domain="$1"
  local email="$2"
  local docroot="$3"
  local server_alias="$4"

  cat > "/etc/apache2/sites-available/${domain}.conf" <<APACHE
<VirtualHost *:80>
    ServerAdmin ${email}
    ServerName ${domain}
${server_alias}
    DocumentRoot ${docroot}

    <Directory ${docroot}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${domain}_error.log
    CustomLog \${APACHE_LOG_DIR}/${domain}_access.log combined
</VirtualHost>
APACHE
}

write_multisite_htaccess() {
  local wp_dir="$1"
  local mode="$2"

  if [[ "$mode" == "subdomain" ]]; then
    cat > "${wp_dir}/.htaccess" <<'HTACCESS'
# BEGIN WordPress Multisite
RewriteEngine On
RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteRule ^wp-admin$ wp-admin/ [R=301,L]
RewriteCond %{REQUEST_FILENAME} -f [OR]
RewriteCond %{REQUEST_FILENAME} -d
RewriteRule ^ - [L]
RewriteRule ^(wp-(content|admin|includes).*) $1 [L]
RewriteRule ^(.*\.php)$ $1 [L]
RewriteRule . index.php [L]
# END WordPress Multisite
HTACCESS
  else
    cat > "${wp_dir}/.htaccess" <<'HTACCESS'
# BEGIN WordPress Multisite
RewriteEngine On
RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteRule ^([_0-9a-zA-Z-]+/)?wp-admin$ $1wp-admin/ [R=301,L]
RewriteCond %{REQUEST_FILENAME} -f [OR]
RewriteCond %{REQUEST_FILENAME} -d
RewriteRule ^ - [L]
RewriteRule ^([_0-9a-zA-Z-]+/)?(wp-(content|admin|includes).*) $2 [L]
RewriteRule ^([_0-9a-zA-Z-]+/)?(.*\.php)$ $2 [L]
RewriteRule . index.php [L]
# END WordPress Multisite
HTACCESS
  fi

  chown www-data:www-data "${wp_dir}/.htaccess"
  chmod 644 "${wp_dir}/.htaccess"
}

hardening_apache_conf() {
  cat > /etc/apache2/conf-available/security-hardening.conf <<'APACHE'
ServerTokens Prod
ServerSignature Off
TraceEnable Off
FileETag None
APACHE
}

write_wp_config() {
  local wp_dir="$1"
  local db_name="$2"
  local db_user="$3"
  local db_password="$4"
  local salts="$5"
  local multisite_mode="$6"

  cat > "${wp_dir}/wp-config.php" <<PHP
<?php
define( 'DB_NAME', '${db_name}' );
define( 'DB_USER', '${db_user}' );
define( 'DB_PASSWORD', '${db_password}' );
define( 'DB_HOST', 'localhost' );
define( 'DB_CHARSET', 'utf8mb4' );
define( 'DB_COLLATE', '' );

${salts}

define( 'WP_REDIS_HOST', '127.0.0.1' );
define( 'WP_REDIS_PORT', 6379 );

define( 'FS_METHOD', 'direct' );
define( 'DISALLOW_FILE_EDIT', true );
define( 'AUTOMATIC_UPDATER_DISABLED', false );

define( 'WP_DEBUG', false );
define( 'FORCE_SSL_ADMIN', true );
define( 'WP_ALLOW_MULTISITE', true );

\$table_prefix = 'wp_';

if ( ! defined( 'ABSPATH' ) ) {
    define( 'ABSPATH', __DIR__ . '/' );
}

require_once ABSPATH . 'wp-settings.php';
PHP

  chown root:www-data "${wp_dir}/wp-config.php"
  chmod 640 "${wp_dir}/wp-config.php"
}

install_wp_cli() {
  if command_exists wp; then
    return
  fi

  curl -fsSL -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
  chmod +x /usr/local/bin/wp
  wp --info >/dev/null
}

main() {
  require_root

  export DEBIAN_FRONTEND=noninteractive

  read -rp "Enter your primary domain name (e.g. example.com): " DOMAIN
  DOMAIN="${DOMAIN%.}"
  if [[ -z "$DOMAIN" ]]; then
    echo "Error: domain name cannot be empty." >&2
    exit 1
  fi

  read -rp "Enter your email address (for Let's Encrypt): " EMAIL
  if [[ -z "$EMAIL" ]]; then
    echo "Error: email address cannot be empty." >&2
    exit 1
  fi

  read -rp "WordPress network admin username: " WP_ADMIN_USER
  if [[ -z "$WP_ADMIN_USER" ]]; then
    echo "Error: WordPress admin username cannot be empty." >&2
    exit 1
  fi

  prompt_secret "WordPress network admin password" WP_ADMIN_PASS

  read -rp "WordPress network title: " WP_TITLE
  if [[ -z "$WP_TITLE" ]]; then
    WP_TITLE="$DOMAIN"
  fi

  read -rp "Install multisite using subdomains or subdirectories? [subdomain/subdirectory]: " MULTISITE_MODE
  MULTISITE_MODE="${MULTISITE_MODE,,}"
  if [[ "$MULTISITE_MODE" != "subdomain" && "$MULTISITE_MODE" != "subdirectory" ]]; then
    echo "Error: choose 'subdomain' or 'subdirectory'." >&2
    exit 1
  fi

  if ! validate_domain "$DOMAIN"; then
    echo "Error: invalid domain name format." >&2
    exit 1
  fi

  local base_id
  base_id="$(sanitize_identifier "$DOMAIN")"
  if [[ -z "$base_id" ]]; then
    echo "Error: failed to derive safe identifiers from domain." >&2
    exit 1
  fi

  DB_NAME="wp_${base_id}"
  DB_USER="u_${base_id}"
  DB_PASSWORD="$(random_password)"
  WORDPRESS_DIR="/var/www/${DOMAIN}/public_html"

  if [[ -e "/etc/apache2/sites-available/${DOMAIN}.conf" || -d "$WORDPRESS_DIR" ]]; then
    echo "Error: an Apache site or WordPress directory already exists for ${DOMAIN}." >&2
    exit 1
  fi

  SERVER_ALIAS=""
  CERTBOT_DOMAINS=("-d" "$DOMAIN")

  if [[ "$MULTISITE_MODE" == "subdirectory" ]]; then
    SERVER_ALIAS="    ServerAlias www.${DOMAIN}"
    CERTBOT_DOMAINS+=("-d" "www.${DOMAIN}")
  fi

  echo "Updating package index..."
  apt-get update

  echo "Installing required packages..."
  apt-get install -y \
    apache2 \
    mariadb-server \
    redis-server \
    certbot \
    python3-certbot-apache \
    curl \
    unzip \
    wget \
    openssl \
    ca-certificates \
    fail2ban \
    ufw \
    php \
    php-cli \
    php-curl \
    php-gd \
    php-imagick \
    php-intl \
    php-mbstring \
    php-mysql \
    php-opcache \
    php-readline \
    php-redis \
    php-xml \
    php-zip \
    libapache2-mod-php

  echo "Starting and enabling services..."
  systemctl enable --now apache2 mariadb redis-server fail2ban

  echo "Configuring firewall..."
  ufw allow OpenSSH
  ufw allow 'Apache Full'
  ufw --force enable

  echo "Configuring fail2ban..."
  cat > /etc/fail2ban/jail.local <<'FAIL2BAN'
[sshd]
enabled = true

[apache-auth]
enabled = true

[apache-badbots]
enabled = true

[apache-noscript]
enabled = true

[apache-overflows]
enabled = true
FAIL2BAN
  systemctl restart fail2ban

  echo "Preparing Apache modules and hardening..."
  a2enmod rewrite ssl headers http2
  hardening_apache_conf
  a2enconf security-hardening

  echo "Creating database and database user..."
  create_db_and_user "$DB_NAME" "$DB_USER" "$DB_PASSWORD"

  echo "Downloading WordPress..."
  mkdir -p "$WORDPRESS_DIR"
  wget -q https://wordpress.org/latest.tar.gz -O /tmp/latest.tar.gz
  tar -xzf /tmp/latest.tar.gz -C "$WORDPRESS_DIR" --strip-components=1
  chown -R www-data:www-data "/var/www/${DOMAIN}"
  find "$WORDPRESS_DIR" -type d -exec chmod 755 {} \;
  find "$WORDPRESS_DIR" -type f -exec chmod 644 {} \;

  echo "Creating Apache virtual host..."
  write_apache_vhost "$DOMAIN" "$EMAIL" "$WORDPRESS_DIR" "$SERVER_ALIAS"
  a2ensite "${DOMAIN}.conf"
  a2dissite 000-default.conf >/dev/null 2>&1 || true
  apachectl configtest
  systemctl reload apache2

  echo "Requesting Let's Encrypt certificate..."
  certbot --apache --non-interactive --agree-tos --redirect \
    --email "$EMAIL" "${CERTBOT_DOMAINS[@]}"

  echo "Installing WP-CLI..."
  install_wp_cli

  echo "Generating WordPress salts..."
  WP_SALTS="$(fetch_wp_salts)"

  echo "Writing wp-config.php..."
  write_wp_config "$WORDPRESS_DIR" "$DB_NAME" "$DB_USER" "$DB_PASSWORD" "$WP_SALTS" "$MULTISITE_MODE"

  echo "Installing WordPress multisite..."
  if [[ "$MULTISITE_MODE" == "subdomain" ]]; then
    run_wp "$WORDPRESS_DIR" core multisite-install \
      --url="https://${DOMAIN}" \
      --title="$WP_TITLE" \
      --admin_user="$WP_ADMIN_USER" \
      --admin_password="$WP_ADMIN_PASS" \
      --admin_email="$EMAIL" \
      --subdomains
  else
    run_wp "$WORDPRESS_DIR" core multisite-install \
      --url="https://${DOMAIN}" \
      --title="$WP_TITLE" \
      --admin_user="$WP_ADMIN_USER" \
      --admin_password="$WP_ADMIN_PASS" \
      --admin_email="$EMAIL"
  fi

  echo "Writing Apache multisite rewrite rules..."
  write_multisite_htaccess "$WORDPRESS_DIR" "$MULTISITE_MODE"

  echo "Setting recommended WordPress options..."
  run_wp "$WORDPRESS_DIR" plugin install redis-cache --activate
  run_wp "$WORDPRESS_DIR" redis enable
  run_wp "$WORDPRESS_DIR" rewrite flush --hard

  chown -R www-data:www-data "/var/www/${DOMAIN}"

  cat <<INFO

WordPress multisite installation completed successfully.

Primary site URL: https://${DOMAIN}
WordPress path: ${WORDPRESS_DIR}
Multisite mode: ${MULTISITE_MODE}
Database name: ${DB_NAME}
Database user: ${DB_USER}
Database password: ${DB_PASSWORD}
Network admin user: ${WP_ADMIN_USER}

Important:
- If you selected subdomain mode, configure a DNS wildcard record for *.${DOMAIN} pointing to this server.
- If you selected subdomain mode behind Apache, a wildcard TLS certificate is not handled by this script.
- Store the database password securely.
INFO
}

main "$@"
