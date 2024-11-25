#!/bin/bash

# Prompt for domain name
read -p "Enter your domain name (e.g., example.com): " DOMAIN

# Prompt for email address for Let's Encrypt
read -p "Enter your email address (for Let's Encrypt SSL): " EMAIL

# Variables
DB_NAME="wordpress_$(echo $DOMAIN | tr . _)"
DB_USER="wp_user_$(echo $DOMAIN | tr . _)"
DB_PASSWORD=$(openssl rand -base64 16) # Generate a random password
DB_ROOT_PASSWORD="root_password" # Update with your MariaDB root password
WORDPRESS_DIR="/var/www/$DOMAIN"

# Update system packages
echo "Updating system packages..."
apt update && apt upgrade -y

# Install required packages
echo "Installing required packages..."
apt install -y apache2 mariadb-server mariadb-client wget curl unzip php php-{cli,curl,gd,imagick,intl,json,mbstring,mysql,opcache,readline,xml,zip} \
    software-properties-common apt-transport-https certbot python3-certbot-apache bash-completion

# Start and enable Apache and MariaDB
echo "Starting and enabling Apache and MariaDB services..."
systemctl start apache2 mariadb
systemctl enable apache2 mariadb

# Secure MariaDB installation
echo "Securing MariaDB..."
mysql_secure_installation <<EOF
n
$DB_ROOT_PASSWORD
$DB_ROOT_PASSWORD
y
y
y
y
EOF

# Configure MariaDB for WordPress
echo "Configuring MariaDB for WordPress..."
mysql -u root -p"$DB_ROOT_PASSWORD" <<EOF
CREATE DATABASE $DB_NAME;
CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

# Create and configure Apache VirtualHost
echo "Creating Apache configuration for $DOMAIN..."
cat <<EOL > /etc/apache2/sites-available/$DOMAIN.conf
<VirtualHost *:80>
    ServerAdmin $EMAIL
    ServerName $DOMAIN
    ServerAlias www.$DOMAIN

    DocumentRoot $WORDPRESS_DIR
    <Directory $WORDPRESS_DIR>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/$DOMAIN_error.log
    CustomLog \${APACHE_LOG_DIR}/$DOMAIN_access.log combined
</VirtualHost>
EOL

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

    # Enable SSL
    SSLEngine on
    SSLCertificateFile /etc/letsencrypt/live/$DOMAIN/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/$DOMAIN/privkey.pem

    # Modern SSL Protocols
    SSLProtocol TLSv1.2 TLSv1.3
    SSLCipherSuite TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256
    SSLHonorCipherOrder On
    SSLSessionTickets Off

    # Enable HSTS
    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"

    # Enable OCSP Stapling
    SSLUseStapling On
    SSLStaplingResponderTimeout 5
    SSLStaplingReturnResponderErrors Off
    SSLStaplingCache "shmcb:/var/run/ocsp_stapling(128000)"

    # Security Headers
    Header always set X-Frame-Options DENY
    Header always set X-Content-Type-Options nosniff
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    Header always set Permissions-Policy "geolocation=(), microphone=(), camera=()"

    ErrorLog \${APACHE_LOG_DIR}/$DOMAIN_error.log
    CustomLog \${APACHE_LOG_DIR}/$DOMAIN_access.log combined
</VirtualHost>
EOL

# Enable Apache configurations
echo "Enabling Apache configurations..."
a2ensite $DOMAIN
a2ensite $DOMAIN-ssl
a2enmod rewrite ssl headers
systemctl reload apache2

# Download and configure WordPress
echo "Downloading and configuring WordPress..."
wget -q https://wordpress.org/latest.tar.gz -O /tmp/latest.tar.gz
mkdir -p $WORDPRESS_DIR
tar -xzf /tmp/latest.tar.gz -C /tmp
mv /tmp/wordpress/* $WORDPRESS_DIR
chown -R www-data:www-data $WORDPRESS_DIR
find $WORDPRESS_DIR -type d -exec chmod 755 {} \;
find $WORDPRESS_DIR -type f -exec chmod 644 {} \;

# Create wp-config.php
echo "Creating WordPress configuration file..."
cat <<EOL > $WORDPRESS_DIR/wp-config.php
<?php
define( 'DB_NAME', '$DB_NAME' );
define( 'DB_USER', '$DB_USER' );
define( 'DB_PASSWORD', '$DB_PASSWORD' );
define( 'DB_HOST', 'localhost' );
define( 'DB_CHARSET', 'utf8mb4' );
define( 'DB_COLLATE', '' );

define('AUTH_KEY',         '$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)');
define('SECURE_AUTH_KEY',  '$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)');
define('LOGGED_IN_KEY',    '$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)');
define('NONCE_KEY',        '$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)');
define('AUTH_SALT',        '$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)');
define('SECURE_AUTH_SALT', '$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)');
define('LOGGED_IN_SALT',   '$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)');
define('NONCE_SALT',       '$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)');

\$table_prefix = 'wp_';
define( 'WP_DEBUG', false );
if ( !defined( 'ABSPATH' ) ) {
    define( 'ABSPATH', dirname( __FILE__ ) . '/' );
}
require_once ABSPATH . 'wp-settings.php';
EOL

# Configure Let's Encrypt SSL
echo "Configuring Let's Encrypt SSL for $DOMAIN..."
certbot --apache --non-interactive --agree-tos --email $EMAIL -d $DOMAIN -d www.$DOMAIN

# Set up automatic SSL renewal
echo "Adding Certbot renewal cron job..."
(crontab -l 2>/dev/null; echo "0 2 * * * certbot renew --quiet >> /var/log/letsencrypt.log") | crontab -

# Reload Apache to apply changes
echo "Reloading Apache..."
systemctl reload apache2

echo "Installation completed! Visit https://$DOMAIN to finish WordPress setup."
