# Name
lua-resty-hmcache - 针对http get 请求缓存有效的防止雪崩效应 
利用 rewrite 执行阶段控制请求是否缓存

# Synopsis
     #设置变量用于lua
     set $ngx_exptime 2;
     set $redis_exptime 120;

     location /api {

         #设置 key
         set $cache_key "$request_method|$host|$request_uri";
         set_escape_uri $escaped_key $cache_key;


         try_files $uri $uri/ /index.php;
         location = /index.php {

             rewrite_by_lua_file /usr/local/openresty/lua-resty-hmcache/resty/main.lua;

             fastcgi_pass   127.0.0.1:9000;
             fastcgi_param  SCRIPT_FILENAME $document_root$fastcgi_script_name;
             include        fastcgi_params;
         }
     }
