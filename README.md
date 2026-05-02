# WordPress on Linux

Install WordPress on Debian or Ubuntu guide and scripts

> Keep it simple. No fancy plugins, no bloated stack. For most sites a VM with 1 vCPU and 1 GB RAM is plenty.

---

## Scripts

| File | Type | Purpose |
|---|---|---|
| `install.txt` | Manual guide | Step-by-step reference for a manual install - original |
| `install_wordpress.sh` | Shell script | Claude Code version |
| `install_wordpress_per.sh` | Shell script | Perplexity version |
| `install_wordpress_gpt.sh` | Shell script | ChatGPT version |
| `installv2.txt` |  Manual guide | Step-by-step reference for a manual install AI enchanced |
| `setup.yml` | Ansible playbook | Full automated server setup — run with `ansible-playbook setup.yml` |
Sites are installed under `/var/www/html/<domain>`.

---

## Recommended Plugins

- [Akismet Anti-Spam](https://wordpress.org/plugins/akismet/)** — install even if comments are disabled.
- [Disable Comments](https://wordpress.org/plugins/disable-comments/)** — removes the comment system entirely.
- [WP Fastest Cache](https://wordpress.org/plugins/wp-fastest-cache/)** — the free version covers most small sites.
- [WP Mail SMTP](https://wordpress.org/plugins/wp-mail-smtp/)** — sends email via an external provider; no mail server needed.

### Optional

- [Google XML Sitemaps](https://wordpress.org/plugins/google-sitemap-generator/)**
- [All-in-One WP Migration](https://wordpress.org/plugins/all-in-one-wp-migration/)**
- [WP DoNotTrack](https://wordpress.org/plugins/wp-donottrack/)**

---

## Hosting

Any of these work well for a small WordPress VPS:

- https://contabo.com/en/
- https://www.hetzner.com/
- https://www.netcup.com/en
- https://www.ionos.de/ 

---

## Performance Tips

- Put a CDN in front — [Cloudflare](https://www.cloudflare.com) has a free plan that works well for small installations.
- Keep WordPress, themes, and plugins updated an to the minimal.

## Security

- Validate your SSL configuration with **[Mozilla SSL Config Generator](https://ssl-config.mozilla.org/)**.
- Scripts enforce TLS 1.3 only with AEAD ciphers, HSTS, OCSP stapling, and HTTP → HTTPS redirect.

---
AI is used to experiment.
*Last updated: May 2026*
