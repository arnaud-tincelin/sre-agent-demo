#!/bin/sh
# Substitute only ${BACKEND_URL} so nginx's own $variables are left untouched.
envsubst '${BACKEND_URL}' \
  < /etc/nginx/templates/default.conf.template \
  > /etc/nginx/conf.d/default.conf
exec nginx -g 'daemon off;'
