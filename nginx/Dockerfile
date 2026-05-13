# Track the Nginx team's stable branch so upstream CVE fixes land automatically.
# Pin to a specific minor (e.g. nginx:1.28-alpine) or digest if stricter
# reproducibility is required for a given deployment.
FROM nginx:stable-alpine

RUN apk upgrade --no-cache \
	&& apk add --no-cache bash openssl

COPY nginx.conf.tpl /customization/
COPY default.conf /etc/nginx/conf.d/
COPY gzip.conf options-ssl-nginx.conf hsts.conf /etc/nginx/includes/
COPY site.conf.tpl /customization/
COPY vhost_service.tpl /customization/
COPY vhost_static.tpl /customization/
COPY vhost_static_gatsby.tpl /customization/
COPY vhost_static_nextjs.tpl /customization/
COPY vhost_redirect.tpl /customization/
COPY vhost_location.tpl /customization/
COPY vhost_location_static.tpl /customization/
COPY vhost_location_sse.tpl /customization/
COPY vhost_location_wss.tpl /customization/
COPY nginx.sh sync_redirect_maps.sh /customization/

RUN chmod +x /customization/nginx.sh /customization/sync_redirect_maps.sh

EXPOSE 80
EXPOSE 443

CMD ["/customization/nginx.sh"]