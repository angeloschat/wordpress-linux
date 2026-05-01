#!/bin/bash

set -e

# Prompt for domain name
read -p "Enter your domain name (e.g., example.com): " DOMAIN
[[ -z "$DOMAIN" ]] && { echo "Error: Domain name cannot be empty."; exit 1; }

# Prompt for email address for Let's Encrypt
read -p "Enter your email address (for Let's Encrypt SSL): " EMAIL
[[ -z "$EMAIL" ]] && { echo "Error: Email address cannot be empty."; exit 1; }

# Prompt for MariaDB root password
read -sp "Enter your MariaDB root password: " DB_ROOT_PASSWORD
echo
[[ -z "$DB_ROOT_PASSWORD" ]] && { echo "Error: MariaDB root password cannot be empty."; exit 1; }

# Variables
DB_NAME="wordpress_$(echo $DOMAIN | tr . _)"
DB_USER="wp_user_$(echo $DOMAIN | tr . _)"
DB_PASSWORD=$(openssl rand -base64 16)
WORDPRESS_DIR="/var/www/html/$DOMAIN"

# Update system packages
echo "Updating system packages..."
apt update && apt upgrade -y

# Install required packages
echo "Installing required packages..."
apt install -y apache2 mariadb-server mariadb-client wget curl unzip \
    php php-{cli,curl,gd,imagick,intl,json,mbstring,mysql,opcache,readline,xml,zip} \
    software-properties-common apt-transport-https certbot python3-certbot-apache bash-completion

# Start and enable Apache and MariaDB
echo "Starting and enabling Apache and MariaDB services..."
systemctl start apache2 mariadb
systemctl enable apache2 mariadb

# Secure MariaDB — try without password (fresh install), skip if already secured
echo "Securing MariaDB..."
if mysql -u root -e "SELECT 1;" 2>/dev/null; then
    mysql -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT_PASSWORD';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
    echo "MariaDB secured."
else
    echo "MariaDB root password already set, skipping initial hardening."
fi

# Configure MariaDB for WordPress
echo "Configuring MariaDB for WordPress..."
mysql -u root -p"$DB_ROOT_PASSWORD" <<EOF
CREATE DATABASE IF NOT EXISTS $DB_NAME;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

# Disable SSL vhost if it was left enabled from a previous run
a2dissite $DOMAIN-ssl 2>/dev/null || true

# Create HTTP VirtualHost — SSL vhost is created after certbot succeeds
echo "Creating Apache HTTP configuration for $DOMAIN..."
cat <<EOL > /etc/apache2/sites-available/$DOMAIN.conf
<VirtualHost *:80>
    ServerAdmin $EMAIL
    ServerName $DOMAIN
    ServerAlias www.$DOMAIN
    DocumentRoot $WORDPRESS_DIR

    RewriteEngine On
    RewriteCond %{REQUEST_URI} !^/\.well-known/
    RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]

    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}_error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}_access.log combined
</VirtualHost>
EOL

# Enable HTTP site and required modules
echo "Enabling Apache HTTP site..."
a2ensite $DOMAIN
a2enmod rewrite ssl headers
apachectl configtest
systemctl reload apache2

# Download and install WordPress (DocumentRoot must exist before certbot webroot auth)
echo "Downloading WordPress..."
mkdir -p $WORDPRESS_DIR
if [ ! -f "$WORDPRESS_DIR/wp-login.php" ]; then
    wget -q https://wordpress.org/latest.tar.gz -O /tmp/latest.tar.gz
    tar -xzf /tmp/latest.tar.gz -C $WORDPRESS_DIR --strip-components=1
    rm /tmp/latest.tar.gz
fi
chown -R www-data:www-data $WORDPRESS_DIR
find $WORDPRESS_DIR -type d -exec chmod 755 {} \;
find $WORDPRESS_DIR -type f -exec chmod 644 {} \;

# Obtain SSL certificate
echo "Obtaining Let's Encrypt SSL certificate for $DOMAIN..."
if ! certbot certonly --webroot -w $WORDPRESS_DIR --non-interactive --agree-tos \
    --email $EMAIL -d $DOMAIN -d www.$DOMAIN; then
    echo "Error: SSL certificate generation failed. Check DNS and ensure port 80 is accessible."
    exit 1
fi

# Create SSL VirtualHost now that the certificate exists
echo "Creating Apache SSL configuration for $DOMAIN..."
cat <<EOL > /etc/apache2/sites-available/$DOMAIN-ssl.conf
<VirtualHost *:443>
    ServerAdmin $EMAIL
    ServerName $DOMAIN
    ServerAlias www.$DOMAIN
    DocumentRoot $WORDPRESS_DIR

    <Directory $WORDPRESS_DIR>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/$DOMAIN/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/$DOMAIN/privkey.pem
    Protocols h2 http/1.1

    SSLProtocol             -all +TLSv1.3
    SSLCipherSuite          TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256
    SSLSessionTickets       off
    SSLCompression          off
    SSLUseStapling          on

    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
    Header always set X-Frame-Options DENY
    Header always set X-Content-Type-Options nosniff
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    Header always set Permissions-Policy "geolocation=(), microphone=(), camera=()"

    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}_error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}_access.log combined
</VirtualHost>
EOL

a2ensite $DOMAIN-ssl
apachectl configtest
systemctl reload apache2

# Create wp-config.php if it doesn't exist
if [ ! -f "$WORDPRESS_DIR/wp-config.php" ]; then
    echo "Creating WordPress configuration file..."
    WP_SALTS=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
    cat <<EOL > $WORDPRESS_DIR/wp-config.php
<?php
define( 'DB_NAME', '$DB_NAME' );
define( 'DB_USER', '$DB_USER' );
define( 'DB_PASSWORD', '$DB_PASSWORD' );
define( 'DB_HOST', 'localhost' );
define( 'DB_CHARSET', 'utf8mb4' );
define( 'DB_COLLATE', '' );

$WP_SALTS

\$table_prefix = 'wp_';
define( 'WP_DEBUG', false );
if ( !defined( 'ABSPATH' ) ) {
    define( 'ABSPATH', dirname( __FILE__ ) . '/' );
}
require_once ABSPATH . 'wp-settings.php';
EOL
    chmod 644 $WORDPRESS_DIR/wp-config.php
fi

# Set up automatic SSL renewal
echo "Adding Certbot renewal cron job..."
(crontab -l 2>/dev/null | grep -v "certbot renew"; echo "0 2 * * * certbot renew --quiet >> /var/log/letsencrypt.log") | crontab -

echo "Installation completed! Visit https://$DOMAIN to finish WordPress setup."
