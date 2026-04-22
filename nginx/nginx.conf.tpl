user nginx;
worker_processes ${workerProcesses};
worker_rlimit_nofile ${workerRlimitNofile};

error_log /var/log/nginx/error.log notice;
pid /var/run/nginx.pid;

events {
    worker_connections ${workerConnections};
    multi_accept ${multiAccept};
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    ${accessLogDirective}

    sendfile on;
    tcp_nopush on;

    keepalive_timeout ${keepaliveTimeout};
    keepalive_requests ${keepaliveRequests};

    ${openFileCacheBlock}

    include /etc/nginx/conf.d/*.conf;
}