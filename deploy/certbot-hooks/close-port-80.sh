#!/bin/sh
# certbot post-hook: /etc/letsencrypt/renewal-hooks/post/close-port-80.sh
#
# Removes the rule open-port-80.sh inserted. certbot runs post-hooks after the
# attempt whether it succeeded or failed. The loop removes every copy, so an
# interrupted earlier run cannot leave port 80 open. It matches the tag, so a
# rule an operator added by hand is left alone.
set -eu

while iptables -C INPUT -p tcp --dport 80 -m comment --comment chickadee-acme -j ACCEPT 2>/dev/null; do
  iptables -D INPUT -p tcp --dport 80 -m comment --comment chickadee-acme -j ACCEPT
done
