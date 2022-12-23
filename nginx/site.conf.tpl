# Real IP Determination
	
# Local subnets:
set_real_ip_from 10.0.0.0/8;
set_real_ip_from 172.0.0.0/12; # Docker subnet
set_real_ip_from 192.168.0.0/16;

real_ip_header X-Real-IP;
real_ip_recursive on;

proxy_set_header              X-Forwarded-Scheme $scheme;
proxy_set_header              X-Forwarded-For $proxy_add_x_forwarded_for;

server {
    listen 80;
    server_name ${domain};    

    location /.well-known/acme-challenge/ {
        root /var/www/certbot/${domain};
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${domain};    

    ssl_certificate /etc/nginx/sites/ssl/dummy/${domain}/fullchain.pem;
    ssl_certificate_key /etc/nginx/sites/ssl/dummy/${domain}/privkey.pem;

    include /etc/nginx/includes/options-ssl-nginx.conf;

    ssl_dhparam /etc/nginx/sites/ssl/ssl-dhparams.pem;

    include /etc/nginx/includes/hsts.conf;

    ${vhostinclude}
}
