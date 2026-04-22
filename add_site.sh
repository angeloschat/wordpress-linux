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
SITE_ROOT="/var/www/html/$DOMAIN"

# Create site directory
echo "Creating site directory..."
mkdir -p $SITE_ROOT

# Create HTTP VirtualHost
echo "Creating Apache configuration for $DOMAIN..."
cat > /etc/apache2/sites-available/$DOMAIN.conf <<EOL
<VirtualHost *:80>
    ServerAdmin $EMAIL
    ServerName $DOMAIN
    ServerAlias www.$DOMAIN
    DocumentRoot $SITE_ROOT

    <Directory $SITE_ROOT>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}_error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}_access.log combined
</VirtualHost>
EOL

# Enable HTTP site and reload Apache
a2ensite $DOMAIN.conf
apachectl configtest
systemctl reload apache2

# Generate Let's Encrypt SSL certificate
echo "Generating SSL certificate for $DOMAIN..."
if ! certbot certonly --webroot -w $SITE_ROOT --non-interactive --agree-tos --email $EMAIL -d $DOMAIN -d www.$DOMAIN; then
    echo "Error: SSL certificate generation failed. Check DNS and ensure port 80 is accessible."
    exit 1
fi

# Create HTTPS VirtualHost
echo "Creating SSL VirtualHost for $DOMAIN..."
cat > /etc/apache2/sites-available/$DOMAIN-ssl.conf <<EOL
<VirtualHost *:443>
    ServerAdmin $EMAIL
    ServerName $DOMAIN
    ServerAlias www.$DOMAIN
    DocumentRoot $SITE_ROOT

    <Directory $SITE_ROOT>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/$DOMAIN/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/$DOMAIN/privkey.pem
    Protocols h2 http/1.1

    SSLProtocol TLSv1.2 TLSv1.3
    SSLCipherSuite TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256
    SSLHonorCipherOrder On
    SSLSessionTickets Off

    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
    Header always set X-Frame-Options DENY
    Header always set X-Content-Type-Options nosniff
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    Header always set Permissions-Policy "geolocation=(), microphone=(), camera=()"

    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}_error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}_access.log combined
</VirtualHost>
EOL

a2ensite $DOMAIN-ssl.conf
apachectl configtest
systemctl reload apache2

# Create MariaDB database and user
echo "Configuring database for $DOMAIN..."
mysql -u root -p"$DB_ROOT_PASSWORD" <<EOF
CREATE DATABASE $DB_NAME;
CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

# Download and extract WordPress
echo "Downloading WordPress..."
wget -q https://wordpress.org/latest.tar.gz -O /tmp/latest.tar.gz
tar -xzf /tmp/latest.tar.gz -C $SITE_ROOT --strip-components=1
rm /tmp/latest.tar.gz
chown -R www-data:www-data $SITE_ROOT
find $SITE_ROOT -type d -exec chmod 755 {} \;
find $SITE_ROOT -type f -exec chmod 644 {} \;

# Fetch WordPress secret keys
echo "Fetching WordPress secret keys..."
WP_SALTS=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)

# Create wp-config.php
echo "Creating WordPress configuration..."
cat > $SITE_ROOT/wp-config.php <<EOL
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

chmod 644 $SITE_ROOT/wp-config.php

echo ""
echo "Site $DOMAIN is ready. Visit https://$DOMAIN to complete WordPress setup."
echo ""
echo "Database credentials:"
echo "  DB Name:     $DB_NAME"
echo "  DB User:     $DB_USER"
echo "  DB Password: $DB_PASSWORD"
