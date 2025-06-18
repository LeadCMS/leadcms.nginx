location  /${location} {
    rewrite /${location}/(.*) /$1  break;
    proxy_pass         ${locationTarget};
    proxy_redirect     off;
    proxy_set_header   Host $host;
    proxy_set_header   X-Real-IP $remote_addr;
    proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header   X-Forwarded-Host $server_name;
    proxy_set_header   X-Forwarded-Proto $scheme;
    client_max_body_size ${maxUploadSize};

    # Upstream recovery and DNS resolver for Docker and external
    proxy_connect_timeout 5s;
    proxy_read_timeout 60s;
    proxy_send_timeout 60s;
    proxy_next_upstream error timeout invalid_header http_502 http_504;
    resolver 127.0.0.11 8.8.8.8 1.1.1.1 valid=10s;
    resolver_timeout 5s;
}