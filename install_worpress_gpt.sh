#!/usr/bin/env bash
set -euo pipefail

echo "WordPress Multi-Site Installer (Hardened + Redis + Backups)"

SERVER_IP=$(curl -s https://api.ipify.org)
echo "Detected public IP: $SERVER_IP"

read -p "How many WordPress sites? " SITE_COUNT

apt update && apt upgrade -y

apt install -y \
  apache2 mariadb-server \
  php php-fpm php-mysql php-cli php-curl php-gd php-mbstring php-xml php-zip php-redis \
  redis-server unzip curl ufw fail2ban libapache2-mod-evasive rsync

systemctl enable redis-server
systemctl start redis-server

ufw allow OpenSSH
ufw allow "Apache Full"
ufw --force enable

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

a2enmod rewrite headers expires remoteip

cat <<EOF > /etc/apache2/conf-available/security-hardening.conf
ServerTokens Prod
ServerSignature Off

<IfModule mod_headers.c>
  Header always set X-Frame-Options "SAMEORIGIN"
  Header always set X-Content-Type-Options "nosniff"
  Header always set X-XSS-Protection "1; mode=block"
  Header always set Referrer-Policy "no-referrer-when-downgrade"
  Header always set Content-Security-Policy "default-src 'self' 'unsafe-inline' 'unsafe-eval' data: https:;"
</IfModule>
EOF

a2enconf security-hardening

cat <<EOF > /etc/apache2/mods-enabled/evasive.conf
<IfModule mod_evasive20.c>
  DOSHashTableSize 3097
  DOSPageCount 5
  DOSSiteCount 50
  DOSPageInterval 1
  DOSSiteInterval 1
  DOSBlockingPeriod 10
</IfModule>
EOF

systemctl restart apache2

curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar
mv wp-cli.phar /usr/local/bin/wp

check_dns() {
  local DOMAIN_TO_CHECK=$1
  RESOLVED_IP=$(getent hosts "$DOMAIN_TO_CHECK" | awk '{print $1}' | head -n1)

  if [[ -z "$RESOLVED_IP" ]]; then
    return 1
  fi

  if [[ "$RESOLVED_IP" == "$SERVER_IP" ]]; then
    return 0
  else
    return 1
  fi
}

DOMAINS=()

for ((i=1;i<=SITE_COUNT;i++)); do

  read -p "Domain: " DOMAIN
  DOMAINS+=("$DOMAIN")

  read -p "DB Name: " DB_NAME
  read -p "DB User: " DB_USER
  read -s -p "DB Password: " DB_PASS; echo
  read -p "Admin User: " WP_ADMIN
  read -s -p "Admin Password: " WP_ADMIN_PASS; echo
  read -p "Admin Email: " WP_EMAIL

  WEBROOT="/var/www/$DOMAIN"

  IFS='.' read -ra PARTS <<< "$DOMAIN"
  if [ "${#PARTS[@]}" -eq 2 ]; then
    ADD_WWW=true
    SERVER_ALIAS="www.${DOMAIN}"
  else
    ADD_WWW=false
    SERVER_ALIAS=""
  fi

  mysql <<EOF
CREATE DATABASE ${DB_NAME} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

  mkdir -p $WEBROOT
  cd /tmp
  curl -O https://wordpress.org/latest.tar.gz
  tar -xzf latest.tar.gz
  rsync -a wordpress/ $WEBROOT/

  chown -R www-data:www-data $WEBROOT
  find $WEBROOT -type d -exec chmod 755 {} \;
  find $WEBROOT -type f -exec chmod 644 {} \;

  cp $WEBROOT/wp-config-sample.php $WEBROOT/wp-config.php

  sed -i "s/database_name_here/${DB_NAME}/" $WEBROOT/wp-config.php
  sed -i "s/username_here/${DB_USER}/" $WEBROOT/wp-config.php
  sed -i "s/password_here/${DB_PASS}/" $WEBROOT/wp-config.php

  curl -s https://api.wordpress.org/secret-key/1.1/salt/ >> $WEBROOT/wp-config.php

  cat <<EOF > /etc/apache2/sites-available/${DOMAIN}.conf
<VirtualHost *:80>
  ServerName ${DOMAIN}
  $( [ "$ADD_WWW" = true ] && echo "ServerAlias ${SERVER_ALIAS}" )

  DocumentRoot ${WEBROOT}

  <Directory ${WEBROOT}>
    AllowOverride All
    Require all granted
  </Directory>

  ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}_error.log
  CustomLog \${APACHE_LOG_DIR}/${DOMAIN}_access.log combined
</VirtualHost>
EOF

  a2ensite ${DOMAIN}

  cd $WEBROOT

  sudo -u www-data wp core install \
    --url="http://${DOMAIN}" \
    --title="${DOMAIN}" \
    --admin_user="${WP_ADMIN}" \
    --admin_password="${WP_ADMIN_PASS}" \
    --admin_email="${WP_EMAIL}"

  sudo -u www-data wp plugin install redis-cache --activate
  sudo -u www-data wp config set WP_REDIS_HOST "127.0.0.1"
  sudo -u www-data wp config set WP_CACHE true --raw
  sudo -u www-data wp redis enable

done

systemctl reload apache2

read -p "Enable Let's Encrypt SSL? (y/n): " SSL_ALL

if [[ "$SSL_ALL" == "y" ]]; then
  apt install -y certbot python3-certbot-apache

  for site in "${DOMAINS[@]}"; do

    IFS='.' read -ra PARTS <<< "$site"

    if [ "${#PARTS[@]}" -eq 2 ]; then
      check_dns "$site" && ROOT_OK=0 || ROOT_OK=1
      check_dns "www.$site" && WWW_OK=0 || WWW_OK=1

      if [[ $ROOT_OK -eq 0 && $WWW_OK -eq 0 ]]; then
        certbot --apache -d "$site" -d "www.$site" \
          --non-interactive --agree-tos -m admin@$site
      fi
    else
      check_dns "$site" && SUB_OK=0 || SUB_OK=1

      if [[ $SUB_OK -eq 0 ]]; then
        certbot --apache -d "$site" \
          --non-interactive --agree-tos -m admin@$site
      fi
    fi

  done
fi

mkdir -p /opt/backups

cat <<'EOF' > /usr/local/bin/wp-backup.sh
#!/usr/bin/env bash
set -e

DATE=$(date +%F)
BACKUP_DIR="/opt/backups/$DATE"
mkdir -p $BACKUP_DIR

for site in /var/www/*; do
  [ -d "$site" ] || continue

  SITE_NAME=$(basename "$site")

  tar -czf "$BACKUP_DIR/${SITE_NAME}_files.tar.gz" -C "$site" .

  DB_NAME=$(grep DB_NAME "$site/wp-config.php" | cut -d "'" -f4)
  DB_USER=$(grep DB_USER "$site/wp-config.php" | cut -d "'" -f4)
  DB_PASS=$(grep DB_PASSWORD "$site/wp-config.php" | cut -d "'" -f4)

  mysqldump -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" > "$BACKUP_DIR/${SITE_NAME}_db.sql"
done

find /opt/backups/* -type d -mtime +7 -exec rm -rf {} \;
EOF

chmod +x /usr/local/bin/wp-backup.sh

cat <<EOF > /etc/cron.d/wp-backups
0 3 * * * root /usr/local/bin/wp-backup.sh
EOF

echo "Installation complete"
