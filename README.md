# WordPress on Linux

Install WordPress on Debian or Ubuntu in a few easy steps.

> **Keep it simple.** No fancy plugins, no bloated stack. For most sites a VM with 1 vCPU and 1 GB RAM is plenty.

---

## Scripts

| Script | Purpose |
|---|---|
| `install.txt` | Full server setup — Apache, MariaDB, PHP-FPM, SSL, WordPress |
| `install_wordpress.sh` | Automated single-site install with Let's Encrypt |
| `install_wordpress_ssl.sh` | Automated single-site install, SSL via webroot method |
| `add_site.sh` | Add a new WordPress site to an existing server |

Sites are installed under `/var/www/html/<domain>`.

---

## Recommended Plugins

- **[Akismet Anti-Spam](https://wordpress.org/plugins/akismet/)** — install even if comments are disabled.
- **[Disable Comments](https://wordpress.org/plugins/disable-comments/)** — removes the comment system entirely.
- **[WP Fastest Cache](https://wordpress.org/plugins/wp-fastest-cache/)** — the free version covers most small sites.
- **[WP Mail SMTP](https://wordpress.org/plugins/wp-mail-smtp/)** — sends email via an external provider; no mail server needed.

### Optional

- **[Google XML Sitemaps](https://wordpress.org/plugins/google-sitemap-generator/)**
- **[All-in-One WP Migration](https://wordpress.org/plugins/all-in-one-wp-migration/)**
- **[WP DoNotTrack](https://wordpress.org/plugins/wp-donottrack/)**

---

## Hosting

Any of these work well for a small WordPress VPS:

- **[Vultr](https://www.vultr.com)** / **[DigitalOcean](https://www.digitalocean.com)** / **[Linode](https://www.linode.com)** — straightforward, predictable pricing.
- **AWS Lightsail** / **Azure** — both have free tiers worth exploring.

---

## Performance Tips

- Put a CDN in front — [Cloudflare](https://www.cloudflare.com) has a free plan that works well for small installations.
- Keep WordPress, themes, and plugins updated.

## Security

- Validate your SSL configuration with **[Mozilla SSL Config Generator](https://ssl-config.mozilla.org/)**.
- Scripts enforce TLS 1.3 only with AEAD ciphers, HSTS, OCSP stapling, and HTTP → HTTPS redirect.

---

*Last updated: January 2026*
