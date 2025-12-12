    location  /${location} {
        # Use variable to enable dynamic resolution and prevent startup failures
        set $upstream ${locationTarget};
        
        # DNS resolver for dynamic resolution
        resolver 127.0.0.11 valid=300s ipv6=off;
        resolver_timeout 10s;
        
        # Error handling for missing upstream
        error_page 502 503 504 = @fallback_${location};
        
        proxy_pass         $upstream;
        proxy_redirect     off;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Host $server_name;
        proxy_set_header   X-Forwarded-Proto $scheme;
        client_max_body_size ${maxUploadSize};

        # Upstream recovery settings
        proxy_connect_timeout 5s;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        proxy_next_upstream error timeout invalid_header http_502 http_503 http_504;
    }

    # Fallback location for ${location} when upstream is not available
    location @fallback_${location} {
        return 503 '<!DOCTYPE html><html><head><title>Service Unavailable</title></head><body><h1>${location} Service Temporarily Unavailable</h1><p>The requested service is currently not available. Please try again later.</p></body></html>';
        add_header Content-Type text/html;
    }