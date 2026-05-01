#!/usr/bin/env bash
set -euo pipefail

echo "=== WordPress Production Installer ==="

# -------------------------------
# 🧾 User Input
# -------------------------------
read -p "Domain (e.g. example.com): " DOMAIN
read -p "DB Name: " DB_NAME
read -p "DB User: " DB_USER
read -s -p "DB Password: " DB_PASS; echo
read -p "WP Admin User: " WP_ADMIN
read -s -p "WP Admin Password: " WP_ADMIN_PASS; echo
read -p "WP Admin Email: " WP_EMAIL

WEBROOT="/var/www/$DOMAIN"

# -------------------------------
# 🔄 System Update
# -------------------------------
apt update && apt upgrade -y

# -------------------------------
# 📦 Install Packages
# -------------------------------
apt install -y \
  apache2 mariadb-server \
  php php-fpm php-mysql php-cli php-curl php-gd php-mbstring php-xml php-zip \
  unzip curl ufw

# -------------------------------
# 🔐 Secure MariaDB + DB Setup
# -------------------------------
echo "Configuring database..."

mysql <<EOF
CREATE DATABASE ${DB_NAME} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

# -------------------------------
# 📥 Install WordPress
# -------------------------------
mkdir -p $WEBROOT
cd /tmp

curl -O https://wordpress.org/latest.tar.gz
tar -xzf latest.tar.gz

rsync -a wordpress/ $WEBROOT/

# -------------------------------
# 🔧 Permissions
# -------------------------------
chown -R www-data:www-data $WEBROOT
find $WEBROOT -type d -exec chmod 755 {} \;
find $WEBROOT -type f -exec chmod 644 {} \;

# -------------------------------
# ⚙️ wp-config.php
# -------------------------------
cp $WEBROOT/wp-config-sample.php $WEBROOT/wp-config.php

sed -i "s/database_name_here/${DB_NAME}/" $WEBROOT/wp-config.php
sed -i "s/username_here/${DB_USER}/" $WEBROOT/wp-config.php
sed -i "s/password_here/${DB_PASS}/" $WEBROOT/wp-config.php

# Secure keys
curl -s https://api.wordpress.org/secret-key/1.1/salt/ >> $WEBROOT/wp-config.php

# -------------------------------
# 🌐 Apache Virtual Host
# -------------------------------
cat <<EOF > /etc/apache2/sites-available/${DOMAIN}.conf
<VirtualHost *:80>
    ServerName ${DOMAIN}
    ServerAlias www.${DOMAIN}
    DocumentRoot ${WEBROOT}

    <Directory ${WEBROOT}>
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}_error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}_access.log combined
</VirtualHost>
EOF

a2enmod rewrite
a2ensite ${DOMAIN}
a2dissite 000-default.conf

systemctl reload apache2

# -------------------------------
# 🔥 Firewall
# -------------------------------
ufw allow OpenSSH
ufw allow "Apache Full"
ufw --force enable

# -------------------------------
# ⚡ PHP Tuning
# -------------------------------
PHP_INI=$(php --ini | grep "Loaded Configuration" | awk '{print $4}')

sed -i "s/upload_max_filesize = .*/upload_max_filesize = 64M/" $PHP_INI
sed -i "s/post_max_size = .*/post_max_size = 64M/" $PHP_INI
sed -i "s/memory_limit = .*/memory_limit = 256M/" $PHP_INI

systemctl reload apache2

# -------------------------------
# 🧰 Install WP-CLI
# -------------------------------
curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar
mv wp-cli.phar /usr/local/bin/wp

# -------------------------------
# ⚙️ WordPress Install
# -------------------------------
cd $WEBROOT

sudo -u www-data wp core install \
  --url="http://${DOMAIN}" \
  --title="${DOMAIN}" \
  --admin_user="${WP_ADMIN}" \
  --admin_password="${WP_ADMIN_PASS}" \
  --admin_email="${WP_EMAIL}"

# -------------------------------
# 🔒 Optional SSL (Certbot)
# -------------------------------
read -p "Enable Let's Encrypt SSL? (y/n): " ENABLE_SSL
if [[ "$ENABLE_SSL" == "y" ]]; then
  apt install -y certbot python3-certbot-apache
  certbot --apache -d ${DOMAIN} -d www.${DOMAIN} --non-interactive --agree-tos -m ${WP_EMAIL}
fi

# -------------------------------
# ✅ Done
# -------------------------------
echo ""
echo "======================================"
echo "✅ WordPress installed successfully!"
echo "🌐 URL: http://${DOMAIN}"
echo "👤 Admin: ${WP_ADMIN}"
echo "======================================"
