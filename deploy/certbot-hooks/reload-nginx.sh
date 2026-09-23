#!/bin/sh
# certbot deploy-hook: /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
#
# certbot runs deploy-hooks only after a certificate was actually renewed.
# nginx reads the certificate when it starts or reloads, so without this it
# keeps serving the old one from memory until it expires, even though the new
# one is on disk.
set -eu

systemctl reload nginx
