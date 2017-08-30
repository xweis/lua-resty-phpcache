# Name
lua-resty-phpcache - 针对openresty + php 组合可以有效的防止缓存失效带来的"雪崩效应"
利用 rewrite 执行阶段控制请求是否缓存

# Synopsis
```nginx
    #设置变量用于lua
    set $ngx_exptime 1;
    set $redis_exptime 120;

    location /api {

        #设置 key
        set $cache_key "$request_method|$host|$request_uri";
        set_escape_uri $escaped_key $cache_key;
        set_md5 $key $escaped_key;

        try_files $uri $uri/ /index.php;
        location = /index.php {

            rewrite_by_lua_file /usr/local/openresty/lua-resty-phpcache/resty/main.lua;

            fastcgi_pass   127.0.0.1:9000;
            fastcgi_param  SCRIPT_FILENAME $document_root$fastcgi_script_name;
            include        fastcgi_params;
        }
    }
```

```lua
-- config.lua

-- 可以配置缓存的 url 以及缓存时间/秒
local cList = {
    ['dev.test.cn'] = {
        ["^/$"] = 10,
        ["^/(\\d+)$"] = 1,
        ["(.*)(.json|.html|.xml|.shtml)$"] = 1,
    },
    ['api.test.com'] = {
        ["^/$"] = 1,
    },
}

return cList

```
