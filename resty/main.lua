-- main.lua

-- 子请求
if ngx.req.get_headers()["x-skip"] == "TRUE" then
    ngx.req.clear_header("Accept-Encoding")
    return
end

require "resty.core.regex"
local hmcache = require "resty.hmcache"

-- 环境 ngx_env
local ngx_env = ngx.var.ngx_env
local cList = require "resty.config.prod.cache"
if ngx_env == 'dev' then
    cList = require "resty.config.dev.cache"
end


local host = ngx.var.host
cList = cList[host] or {}
local re_find = ngx.re.find
local is_cache = nil

local request_uri = ngx.var.request_uri
local method = ngx.req.get_method()
local uri = ngx.re.sub(request_uri, "\\?.*", "")

for regex, exptime in pairs(cList) do
    local from, to, err = re_find(uri, regex, "ijo")
    if err then
        ngx.log(ngx.ERR,err)
    end

    -- 缓存
    if from then
        is_cache = 1
        ngx.var.redis_exptime = exptime
        break
    end
end

-- 不缓存
if not is_cache then
    return
end

-- 只缓存 get 请求
if ngx.var.request_method == "GET" then

    -- 缓存 key
    local cache_keys = {
        method,
        host,
        request_uri,
    }
    local cache_key = string.lower(table.concat(cache_keys,"|"))
    local key = 'ngx_cache_' .. ngx.md5(cache_key)

    local cache = hmcache:new()
    local content, err = cache:get(key)

    if not content then 
        if err then
            ngx.log(ngx.ERR, err)
        end
        return 
    end

    ngx.status = content.status
    ngx.print(content.body)
    return ngx.exit(content.status)
end
return
