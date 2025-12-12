    location ${ssePath} {
        # Use variable to enable dynamic resolution
        set $upstream ${target};
        
        # DNS resolver for dynamic resolution
        resolver 127.0.0.11 valid=300s ipv6=off;
        resolver_timeout 10s;
        
        proxy_pass         $upstream;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Host $server_name;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header   Connection '';
        proxy_buffering    off;
        proxy_cache        off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        chunked_transfer_encoding off;
    }