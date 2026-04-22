#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  sudo ./add_site_after_installv2.sh <domain.tld> <db_name> <db_user> <db_pass> <email>

Example:
  sudo ./add_site_after_installv2.sh blog.example.com wp_blog wp_blog_user 'StrongPass123!' admin@example.com

What this script does:
  - Creates /var/www/html/<domain.tld>
  - Downloads latest WordPress into that directory
  - Creates MariaDB database and user
  - Requests Let's Encrypt certificate (domain + www)
  - Creates strict Apache HTTP->HTTPS + TLS vhosts
USAGE
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 5 ]]; then
  echo "Error: expected 5 arguments, got $#." >&2
  usage
  exit 1
fi

DOMAIN="$1"
DB_NAME="$2"
DB_USER="$3"
DB_PASS="$4"
EMAIL="$5"
SITE_ROOT="/var/www/html/${DOMAIN}"
VHOST_FILE="/etc/apache2/sites-available/${DOMAIN}.conf"
CERT_PATH="/etc/letsencrypt/live/${DOMAIN}"

if [[ $EUID -ne 0 ]]; then
  echo "Error: run this script with sudo/root." >&2
  exit 1
fi

if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
  echo "Error: DOMAIN must look like domain.tld" >&2
  exit 1
fi

for required_cmd in apache2ctl mysql certbot rsync wget curl; do
  if ! command -v "$required_cmd" >/dev/null 2>&1; then
    echo "Error: missing required command: ${required_cmd}. Run installv2 first." >&2
    exit 1
  fi
done

if ! systemctl is-enabled --quiet apache2 2>/dev/null; then
  echo "Error: apache2 service not found/enabled. Run installv2 first." >&2
  exit 1
fi

if [[ -e "$SITE_ROOT" && -n "$(find "$SITE_ROOT" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
  echo "Error: ${SITE_ROOT} already exists and is not empty." >&2
  exit 1
fi

mkdir -p "$SITE_ROOT"
chown -R www-data:www-data "$SITE_ROOT"

mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

wget -q https://wordpress.org/latest.tar.gz -O "$tmp_dir/latest.tar.gz"
tar -xzf "$tmp_dir/latest.tar.gz" -C "$tmp_dir"
rsync -a --delete "$tmp_dir/wordpress/" "$SITE_ROOT/"

if [[ ! -f "$SITE_ROOT/wp-config.php" ]]; then
  cp "$SITE_ROOT/wp-config-sample.php" "$SITE_ROOT/wp-config.php"
fi

sed -i "s/database_name_here/${DB_NAME}/" "$SITE_ROOT/wp-config.php"
sed -i "s/username_here/${DB_USER}/" "$SITE_ROOT/wp-config.php"
sed -i "s/password_here/${DB_PASS}/" "$SITE_ROOT/wp-config.php"

SALT="$(curl -fsSL https://api.wordpress.org/secret-key/1.1/salt/)"
awk -v salts="$SALT" '
  BEGIN{added=0}
  /AUTH_KEY|SECURE_AUTH_KEY|LOGGED_IN_KEY|NONCE_KEY|AUTH_SALT|SECURE_AUTH_SALT|LOGGED_IN_SALT|NONCE_SALT/ && added==0 {
    print salts
    added=1
    next
  }
  !/AUTH_KEY|SECURE_AUTH_KEY|LOGGED_IN_KEY|NONCE_KEY|AUTH_SALT|SECURE_AUTH_SALT|LOGGED_IN_SALT|NONCE_SALT/ {print}
' "$SITE_ROOT/wp-config.php" > "$tmp_dir/wp-config.php"
mv "$tmp_dir/wp-config.php" "$SITE_ROOT/wp-config.php"

chown -R www-data:www-data "$SITE_ROOT"
find "$SITE_ROOT" -type d -exec chmod 755 {} \;
find "$SITE_ROOT" -type f -exec chmod 644 {} \;
chmod 640 "$SITE_ROOT/wp-config.php"

a2enmod rewrite ssl headers http2 >/dev/null

# Temporary HTTP vhost for ACME challenge
cat > "$VHOST_FILE" <<APACHE_HTTP
<VirtualHost *:80>
    ServerName ${DOMAIN}
    ServerAlias www.${DOMAIN}
    DocumentRoot ${SITE_ROOT}

    <Directory ${SITE_ROOT}>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}_error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}_access.log combined
</VirtualHost>
APACHE_HTTP

a2ensite "${DOMAIN}.conf" >/dev/null
apache2ctl -t
systemctl reload apache2

certbot certonly \
  --webroot -w "${SITE_ROOT}" \
  --non-interactive \
  --agree-tos \
  --email "${EMAIL}" \
  -d "${DOMAIN}" -d "www.${DOMAIN}"

if [[ ! -f "${CERT_PATH}/fullchain.pem" || ! -f "${CERT_PATH}/privkey.pem" ]]; then
  echo "Error: certificate files were not created for ${DOMAIN}." >&2
  exit 1
fi

cat > "$VHOST_FILE" <<APACHE_TLS
<VirtualHost *:80>
    ServerName ${DOMAIN}
    ServerAlias www.${DOMAIN}
    RewriteEngine On
    RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L,NE]
</VirtualHost>

<VirtualHost *:443>
    ServerName ${DOMAIN}
    ServerAlias www.${DOMAIN}
    DocumentRoot ${SITE_ROOT}

    Protocols h2 http/1.1

    <Directory ${SITE_ROOT}>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    SSLEngine on
    SSLCertificateFile ${CERT_PATH}/fullchain.pem
    SSLCertificateKeyFile ${CERT_PATH}/privkey.pem

    SSLProtocol -all +TLSv1.2 +TLSv1.3
    SSLHonorCipherOrder on
    SSLCipherSuite HIGH:!aNULL:!MD5:!3DES
    SSLCompression off
    SSLSessionTickets off

    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-Content-Type-Options "nosniff"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    Header always set Permissions-Policy "geolocation=(), microphone=(), camera=()"

    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}_ssl_error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}_ssl_access.log combined
</VirtualHost>
APACHE_TLS

apache2ctl -t
systemctl reload apache2

if ! curl -fsSI "https://${DOMAIN}" >/dev/null; then
  echo "Error: HTTPS validation failed for https://${DOMAIN}" >&2
  exit 1
fi

echo "Done. New WordPress site is available at ${SITE_ROOT} (HTTPS enabled with strict TLS config)."
