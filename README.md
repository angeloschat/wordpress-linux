**Install Wordpress on Debian or Ubuntu in few easy steps.**

Updated on February 2024

Keep it simple. No need for funcy plugins or many services. 
For most cases a virtual machine with 1vCPU and 1GB RAM is enough.
Also use a CDN it helps a lot. Cloudflare is a good option (has a free plan that is perfect for small sized installations).

Some **recommended** plugins
- Akismet antispam https://wordpress.org/plugins/akismet/ install it even if comments are disabled.
- Disable comments https://wordpress.org/plugins/disable-comments/ (install it if you do not like critiscm like me)
- WP Fastest cache  https://wordpress.org/plugins/wp-fastest-cache/ In most cases the freeversion is enough. 
  But if you want to get serious I strongly recomend the paid version its worth ever penny.  https://www.wpfastestcache.com/
- WP mail SMTP https://wordpress.org/plugins/wp-mail-smtp/ No need to install mail server on your linuc box.
**Optional** plugins
- Google XML Sitemaps https://wordpress.org/plugins/google-sitemap-generator/
- All-in-One WP Migration https://wordpress.org/plugins/all-in-one-wp-migration/
- WP DoNotTrack https://wordpress.org/plugins/wp-donottrack/

If you are looking for hosting your virtual machine (or vps as they called nowdays)
Vultr, digital ocean or Linode are all very good options. Another option is to use AWS Ligtsale but it is untested by me.
Both AWS and Azure offer free tiers worth of trying.

Make you webserver installation more secure. Check out this nice tool **https://ssl-config.mozilla.org/**



