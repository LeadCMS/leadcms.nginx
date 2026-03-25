location / {
    root ${target};
    index ${index};
    add_header Cache-Control "public, max-age=0, must-revalidate" always;
    try_files $uri $uri/ $uri.html =404;
    error_page 404 /404.html;
}

location ~* \.html$ {
    root ${target};
    add_header Cache-Control "public, max-age=0, must-revalidate" always;
    try_files $uri $uri/ =404;
}

location ~* \.(js|css|woff2?|ttf|eot|svg|jpg|jpeg|png|avif|gif|ico)$ {
    root ${target};
    add_header Cache-Control "public, max-age=31536000, immutable" always;
    try_files $uri =404;
}

${locationTemplatePlaceholder}
