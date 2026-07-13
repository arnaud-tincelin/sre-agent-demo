#!/bin/sh
# Derive the backend host (strip scheme + any path) so nginx can send the
# correct Host header / TLS SNI to the ACA internal ingress.
export BACKEND_HOST="$(printf '%s' "$BACKEND_URL" | sed -e 's#^[a-zA-Z]*://##' -e 's#/.*$##')"

# Substitute only our own variables so nginx's $variables are left untouched.
envsubst '${BACKEND_URL} ${BACKEND_HOST}' \
  < /etc/nginx/templates/default.conf.template \
  > /etc/nginx/conf.d/default.conf
exec nginx -g 'daemon off;'
