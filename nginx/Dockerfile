FROM nginx:1.23-alpine

RUN apk add --no-cache bash
RUN apk add --no-cache openssl

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
COPY nginx.sh /customization/

RUN chmod +x /customization/nginx.sh

EXPOSE 80
EXPOSE 443

CMD ["/customization/nginx.sh"]