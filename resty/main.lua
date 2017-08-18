-- main.lua

local cache = require "resty.hmcache"

if ngx.req.get_headers()["x-skip"] == "TRUE" then
    ngx.req.clear_header("Accept-Encoding")
    return
end

if ngx.var.request_method == "GET" then

    cache = cache:new()
    local content, err = cache:get(ngx.var.key)

    if not content then 
        ngx.log(ngx.ERR, err)
        return 
    end

    ngx.print(content)
    return ngx.exit(ngx.HTTP_OK)
end
return
