**Install Wordpress on Debian or Ubuntu in few easy steps.**

Updated on January 2026

Keep it simple. No need for fancy plugins or many services. 
For most cases a virtual machine with 1vCPU and 1GB RAM is enough.
Also use a CDN it helps a lot. Cloudflare is a good option (has a free plan that is perfect for small sized installations).

Some **recommended** plugins
- Akismet antispam https://wordpress.org/plugins/akismet/ install it even if comments are disabled.
- Disable comments https://wordpress.org/plugins/disable-comments/ (install it if you do not like criticism like me)
- WP Fastest cache  https://wordpress.org/plugins/wp-fastest-cache/ In most cases the free version is enough.
- WP mail SMTP https://wordpress.org/plugins/wp-mail-smtp/ No need to install mail server on your linux box.
**Optional** plugins
- Google XML Sitemaps https://wordpress.org/plugins/google-sitemap-generator/
- All-in-One WP Migration https://wordpress.org/plugins/all-in-one-wp-migration/
- WP DoNotTrack https://wordpress.org/plugins/wp-donottrack/

If you are looking for hosting your virtual machine (or vps as they called nowdays)
Vultr, digital ocean or Linode are all very good options. Another option is to use AWS Lightsail but it is untested by me.
Both AWS and Azure offer free tiers worth of trying.

Make you webserver installation more secure. Check out this nice tool **https://ssl-config.mozilla.org/**




## Add more sites after installv2

Use the helper script to provision a new WordPress vhost after the base server is already configured:

```bash
sudo ./add_site_after_installv2.sh domain.tld db_name db_user db_pass admin@email.tld
```

This creates the site in `/var/www/html/domain.tld`, configures Apache + MariaDB + WordPress, enforces HTTP->HTTPS redirect, and enables a strict TLS configuration with Let's Encrypt certificates.
