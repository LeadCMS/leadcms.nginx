location  /${location} {    
    rewrite /${location}/(.*) /$1  break;
    proxy_pass         ${locationTarget};
    proxy_redirect     off;
    proxy_set_header   Host $host;
    proxy_set_header   X-Real-IP $remote_addr;
    proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header   X-Forwarded-Host $server_name;
    proxy_set_header   X-Forwarded-Proto $scheme;
    proxy_set_header   X-Forwarded-Server $host;
    add_header         X-Served-By $host;
    client_max_body_size ${maxUploadSize};
}
