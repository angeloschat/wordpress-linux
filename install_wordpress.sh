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

# Prompt for WordPress admin credentials
read -p "WordPress admin username: " WP_ADMIN_USER
[[ -z "$WP_ADMIN_USER" ]] && { echo "Error: Admin username cannot be empty."; exit 1; }
read -sp "WordPress admin password: " WP_ADMIN_PASS
echo
[[ -z "$WP_ADMIN_PASS" ]] && { echo "Error: Admin password cannot be empty."; exit 1; }
read -p "WordPress site title: " WP_TITLE
[[ -z "$WP_TITLE" ]] && WP_TITLE="$DOMAIN"

# Variables
DB_NAME="wordpress_$(echo $DOMAIN | tr . _)"
DB_USER="wp_user_$(echo $DOMAIN | tr . _)"
DB_PASSWORD=$(openssl rand -base64 16)
WORDPRESS_DIR="/var/www/html/$DOMAIN"

IFS='.' read -ra DOMAIN_PARTS <<< "$DOMAIN"
if [ "${#DOMAIN_PARTS[@]}" -eq 2 ]; then
    WWW_ALIAS="ServerAlias www.$DOMAIN"
    CERTBOT_DOMAINS="-d $DOMAIN -d www.$DOMAIN"
else
    WWW_ALIAS=""
    CERTBOT_DOMAINS="-d $DOMAIN"
fi

# Update system packages
echo "Updating system packages..."
apt update && apt upgrade -y

# Install required packages
echo "Installing required packages..."
apt install -y apache2 mariadb-server mariadb-client wget curl unzip \
    php php-{cli,curl,gd,imagick,intl,json,mbstring,mysql,opcache,readline,redis,xml,zip} \
    redis-server ufw fail2ban \
    software-properties-common apt-transport-https certbot python3-certbot-apache bash-completion

# Start and enable Apache, MariaDB, and Redis
echo "Starting and enabling Apache, MariaDB, and Redis services..."
systemctl start apache2 mariadb redis-server
systemctl enable apache2 mariadb redis-server

# Configure UFW firewall
echo "Configuring firewall..."
ufw allow OpenSSH
ufw allow "Apache Full"
ufw --force enable

# Configure fail2ban
echo "Configuring fail2ban..."
cat <<EOF > /etc/fail2ban/jail.local
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
EOF
systemctl enable fail2ban
systemctl restart fail2ban

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

# Download WordPress
echo "Downloading WordPress..."
mkdir -p $WORDPRESS_DIR
wget -q https://wordpress.org/latest.tar.gz -O /tmp/latest.tar.gz
tar -xzf /tmp/latest.tar.gz -C $WORDPRESS_DIR --strip-components=1
chown -R www-data:www-data $WORDPRESS_DIR
find $WORDPRESS_DIR -type d -exec chmod 755 {} \;
find $WORDPRESS_DIR -type f -exec chmod 644 {} \;

# Obtain SSL certificate via standalone (certbot binds port 80 directly)
echo "Obtaining Let's Encrypt SSL certificate for $DOMAIN..."
systemctl stop apache2
if ! certbot certonly --standalone --non-interactive --agree-tos \
    --email "$EMAIL" $CERTBOT_DOMAINS; then
    systemctl start apache2
    echo "Error: SSL certificate generation failed. Check DNS and ensure port 80 is accessible."
    exit 1
fi
systemctl start apache2

# Create HTTP VirtualHost (redirect only — SSL vhost handles all real traffic)
echo "Creating Apache HTTP configuration for $DOMAIN..."
cat <<EOL > /etc/apache2/sites-available/$DOMAIN.conf
<VirtualHost *:80>
    ServerAdmin $EMAIL
    ServerName $DOMAIN
    $WWW_ALIAS

    RewriteEngine On
    RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]

    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}_error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}_access.log combined
</VirtualHost>
EOL

# Enable HTTP site and required modules, then restart
echo "Enabling Apache HTTP site..."
a2ensite $DOMAIN
a2enmod rewrite ssl headers
systemctl restart apache2

# Create SSL VirtualHost now that the certificate exists
echo "Creating Apache SSL configuration for $DOMAIN..."
cat <<EOL > /etc/apache2/sites-available/$DOMAIN-ssl.conf
<VirtualHost *:443>
    ServerAdmin $EMAIL
    ServerName $DOMAIN
    $WWW_ALIAS
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

# SSLStaplingCache must be at server level — required when SSLUseStapling is on
echo "SSLStaplingCache shmcb:/run/apache2/ocsp(128000)" \
    > /etc/apache2/conf-available/ssl-stapling.conf
a2enconf ssl-stapling

apachectl configtest
systemctl reload apache2

# Fetch WordPress secret keys and create wp-config.php
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

define( 'WP_REDIS_HOST', '127.0.0.1' );
define( 'WP_REDIS_PORT', 6379 );
define( 'WP_CACHE', true );

\$table_prefix = 'wp_';
define( 'WP_DEBUG', false );
if ( !defined( 'ABSPATH' ) ) {
    define( 'ABSPATH', dirname( __FILE__ ) . '/' );
}
require_once ABSPATH . 'wp-settings.php';
EOL
chmod 644 $WORDPRESS_DIR/wp-config.php

# Install WP-CLI
echo "Installing WP-CLI..."
curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar
mv wp-cli.phar /usr/local/bin/wp

# Run WordPress core install to create database tables
echo "Running WordPress installation..."
sudo -u www-data wp core install \
    --url="https://$DOMAIN" \
    --title="$WP_TITLE" \
    --admin_user="$WP_ADMIN_USER" \
    --admin_password="$WP_ADMIN_PASS" \
    --admin_email="$EMAIL" \
    --path="$WORDPRESS_DIR"

# Activate Redis object cache plugin
echo "Enabling Redis cache..."
sudo -u www-data wp plugin install redis-cache --activate --path="$WORDPRESS_DIR"
sudo -u www-data wp redis enable --path="$WORDPRESS_DIR"

# Create backup script
echo "Setting up backup script..."
mkdir -p /opt/backups
cat <<EOF > /usr/local/bin/wp-backup.sh
#!/usr/bin/env bash
set -e
DATE=\$(date +%F)
BACKUP_DIR="/opt/backups/\$DATE"
mkdir -p "\$BACKUP_DIR"
SITE="$DOMAIN"
WEBROOT="$WORDPRESS_DIR"
tar -czf "\$BACKUP_DIR/\${SITE}_files.tar.gz" -C "\$WEBROOT" .
DB_NAME=\$(grep "DB_NAME" "\$WEBROOT/wp-config.php" | cut -d "'" -f4)
DB_USER=\$(grep "DB_USER" "\$WEBROOT/wp-config.php" | cut -d "'" -f4)
DB_PASS=\$(grep "DB_PASSWORD" "\$WEBROOT/wp-config.php" | cut -d "'" -f4)
mysqldump -u "\$DB_USER" -p"\$DB_PASS" "\$DB_NAME" > "\$BACKUP_DIR/\${SITE}_db.sql"
find /opt/backups -maxdepth 1 -type d -mtime +7 -exec rm -rf {} \;
EOF
chmod +x /usr/local/bin/wp-backup.sh

# Add both backup and SSL renewal to root crontab (visible via crontab -l)
echo "Adding cron jobs..."
(crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/wp-backup.sh >> /var/log/wp-backup.log 2>&1") | crontab -
(crontab -l 2>/dev/null; echo "0 2 * * * certbot renew --quiet >> /var/log/letsencrypt.log 2>&1") | crontab -

echo "Installation completed! Visit https://$DOMAIN to finish WordPress setup."
