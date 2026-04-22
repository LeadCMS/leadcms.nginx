${proxyResolverTemplatePlaceholder}

recursive_error_pages on;
error_page 404 $custom_404;

location ~ (^|/)404(?:/index)?\.html$ {
    internal;
    root ${target};
    try_files $uri =404;
}

location / {
    root ${target};
    index ${index};
    error_page 404 = @custom_404;
    try_files $uri $uri/ =404;
}

location @custom_404 {
    internal;
    root ${target};
    set $custom_404 /404/index.html;
    set $error_path /__missing__;
    set $error_base_1 /__missing__;
    set $error_base_2 /__missing__;
    set $error_base_3 /__missing__;
    set $error_base_4 /__missing__;
    set $error_base_5 /__missing__;
    set $error_base_6 /__missing__;

    if ($uri ~ "^(.+[^/])/?$") { set $error_path $1; }

    if ($error_path ~ "^((?:/[^/]+){1})(?:/.*)?$") { set $error_base_1 $1; }
    if ($error_path ~ "^((?:/[^/]+){2})(?:/.*)?$") { set $error_base_2 $1; }
    if ($error_path ~ "^((?:/[^/]+){3})(?:/.*)?$") { set $error_base_3 $1; }
    if ($error_path ~ "^((?:/[^/]+){4})(?:/.*)?$") { set $error_base_4 $1; }
    if ($error_path ~ "^((?:/[^/]+){5})(?:/.*)?$") { set $error_base_5 $1; }
    if ($error_path ~ "^((?:/[^/]+){6})(?:/.*)?$") { set $error_base_6 $1; }

    if (-f $document_root/404/index.html) { set $custom_404 /404/index.html; }
    if (-f $document_root/404.html) { set $custom_404 /404.html; }

    if (-f $document_root$error_base_1/404/index.html) { set $custom_404 $error_base_1/404/index.html; }
    if (-f $document_root$error_base_1/404.html) { set $custom_404 $error_base_1/404.html; }

    if (-f $document_root$error_base_2/404/index.html) { set $custom_404 $error_base_2/404/index.html; }
    if (-f $document_root$error_base_2/404.html) { set $custom_404 $error_base_2/404.html; }

    if (-f $document_root$error_base_3/404/index.html) { set $custom_404 $error_base_3/404/index.html; }
    if (-f $document_root$error_base_3/404.html) { set $custom_404 $error_base_3/404.html; }

    if (-f $document_root$error_base_4/404/index.html) { set $custom_404 $error_base_4/404/index.html; }
    if (-f $document_root$error_base_4/404.html) { set $custom_404 $error_base_4/404.html; }

    if (-f $document_root$error_base_5/404/index.html) { set $custom_404 $error_base_5/404/index.html; }
    if (-f $document_root$error_base_5/404.html) { set $custom_404 $error_base_5/404.html; }

    if (-f $document_root$error_base_6/404/index.html) { set $custom_404 $error_base_6/404/index.html; }
    if (-f $document_root$error_base_6/404.html) { set $custom_404 $error_base_6/404.html; }

    if (-f $document_root$error_path/404/index.html) { set $custom_404 $error_path/404/index.html; }
    if (-f $document_root$error_path/404.html) { set $custom_404 $error_path/404.html; }

    return 404;
}

${locationTemplatePlaceholder}