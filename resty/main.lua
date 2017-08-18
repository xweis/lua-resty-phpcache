-- main.lua

-- 子请求
if ngx.req.get_headers()["x-skip"] == "TRUE" then
    ngx.req.clear_header("Accept-Encoding")
    return
end

require "resty.core.regex"
local cache = require "resty.hmcache"
local cList = require "resty.config"
local re_find = ngx.re.find
local is_cache = nil
local uri = ngx.re.sub(ngx.var.request_uri, "\\?.*", "")

for regex, exptime in pairs(cList) do
    local from, to, err = re_find(uri, regex, "ijo")
    if err then
        ngx.log(ngx.ERR,err)
    end

    if from then
        is_cache = 1
        ngx.var.redis_exptime = exptime
        break
    end
end

if not is_cache then
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
