-- Copyright (C) Huo Mao (@)
-- 访问php 数据保存到redis和ngxcache 
-- php timeout 10s 
-- 如果超时访问托底数据，1分钟后再请求php 
 

local redis = require "resty.redis_iresty" 
local resty_lock = require "resty.lock"
local http = require "resty.http"
local cjson = require "cjson"
local ngx_re = require "ngx.re"
local shared = ngx.shared
--local red = redis:new({host='10.0.0.17',auth='HCeNPa109XzzfqpC'})
local red = redis:new({host='127.0.0.1',auth=nil})
local setmetatable = setmetatable
local lockName = "lock"

local _M = { _VERSION = '0.02' }
local mt = { __index = _M }

local ERR = ngx.ERR
local NOTICE = ngx.NOTICE
local log = ngx.log

function _M.new(_, dict_name, domain)
    
    local ngxCache = shared[dict_name]
    if not ngxCache then
        return nil, "dictionary not found"
    end

    if not domain then
        log(ERR, "domain is not")
        ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    local ngx_exptime = ngx.var.ngx_exptime or 1
    local redis_exptime = ngx.var.redis_exptime or 10
    local re_exptime = ngx.var.re_exptime or 10
    local proxy_timeout = ngx.var.proxy_timeout or 5000
    local X_Cache_hm = "miss" 

    local self = {
        ngxCache = ngxCache,
        ngx_exptime = ngx_exptime,
        redis_exptime = redis_exptime,
        re_exptime = re_exptime,
        domain = domain,
        proxy_timeout = proxy_timeout,
        X_Cache_hm = X_Cache_hm, 
    }
    return setmetatable(self, mt)
end


-- ngx内部缓存 get
function _M.shmGet(self, key)
    
    local ngxCache = self.ngxCache
    local val, err = ngxCache:get(key)
    if val then
        self.X_Cache_hm = "His"
        return val
    end
    
    if err then return nil, "failed to get key from ngxCache : " .. err end

    return nil, "'" .. key .. "' cache Key not exist"

end


-- ngx内部缓存 set
function _M.shmSet(self, key, value, exptime)
    
    if not exptime then
        exptime = self.ngx_exptime
    end
    local ngxCache = self.ngxCache
    local val, err = ngxCache:set(key, value, exptime)
    if val then
        return val
    end
    
    if err then return nil, "failed to get key from ngxCache : " .. err end

    return nil, "'" .. key .. "' cache Key not exist"

end


-- return key, query url, proxy url
function query_uri(proxy_host)

    -- 获取请求uri 地址 
    local uri = ngx.re.sub(ngx.var.request_uri, "\\?.*", "") 
    -- 拼接key 如: "get http://www.example.com/uri?args"
    local query = {ngx.var.request_method, " ",ngx.var.scheme, "://",ngx.var.host,uri,}
    -- 请求后端php uri 如: "http://proxy_host/uri?args"
    local proxy = {proxy_host,uri,}

    local args = ngx.req.get_uri_args()
    args = ngx.encode_args(args)
    if args ~= "" then
        query[#query + 1] = "?"
        query[#query + 1] = args
    end
    query = table.concat(query)
    proxy = table.concat(proxy)

    local key = ngx.md5(query)

    return key, query, proxy, args 
end


function _M.get(self)

    -- local method = ngx.req.get_method()
    -- log(ERR,method)

    if not self then
        return nil, "uri or self no value, not running :new()"
    end

    local key, uri, proxy, args = query_uri(self.domain)

    -- 获取ngxcache数据
    local val, err  = self.shmGet(self, key)
    if val then
        return self.header(self,val)
    end

    -- 创建锁 
    local lock, err = resty_lock:new(lockName)
    if not lock then
        return nil, "failed to create lock: " .. err
    end

    local elapsed, err = lock:lock(key)
    -- 没有获取锁
    if not elapsed then
        local val, err = red:get(key .. "_bottomData")
        if not val then
            return nil, "failed Redis get bottomData"
        end
        return self.header(self,val)
    end


    -- 成功得到锁!

    -- 有请求可能已经把值放到缓存中了 
    -- 所以我们在查询一遍
    val, err  = self.shmGet(self, key)
    if val then
        local ok, err = lock:unlock()
        if not ok then
            return nil, "failed to unlock: " .. err
        end

        return self.header(self,val)
    end


    -- Redis 没有数据,proxy 后端获取
    local val, status, fetch_redis_err = self.fetch_redis(self, key, proxy, args)
    if not val then
        local ok, err = lock:unlock()
        if not ok then
            return nil, "failed to unlock: " .. err
        end

        -- php redis 挂掉,且获取托底数据失败 | status 非200 

        log(NOTICE, '(status:' .. status .. ") " .. fetch_redis_err .. uri )

        return nil, status
    end


    -- 用新获取的值更新ngxcache缓存 
    local ok, err = self.shmSet(self, key, val, self.ngx_exptime)
    if not ok then
        local ok, err = lock:unlock()
        if not ok then
            return nil, "failed to unlock: " .. err
        end

        return nil, "failed to update shm cache: " 
    end

    local ok, err = lock:unlock()
    if not ok then
        return nil, "failed to unlock: " .. err
    end

    return self.header(self,val)
end


-- 保存redis数据，并创建托底数据
-- return string 
function _M.fetch_redis(self, key, uri, args)

    local value,err = red:get(key)
    if value then
        self.X_Cache_hm = "His"
        return value
    end

    local http_error = self.shmGet(self, key .. "_httpGet_error")
    if http_error == 1 then
        local value, err = red:get(key .. "_bottomData")
        if value then
            log(NOTICE, "Get bottomData succ " .. uri)
            self.X_Cache_hm = "His bot"
            return value
        end
    end

    -- value = ngx.location.capture(uri)
    value = self.httpGet(self, key, uri, args)

    -- status 返回 200
    if value and value.status == ngx.HTTP_OK then
        local content_type = 'text/html; charset=UTF-8 \r\n\r\n'
        if value.headers['content_type'] then
            content_type = value.headers['content_type'] .. "\r\n\r\n"
        end

        value = content_type .. value.body
        local ok, err = red:set(key, value)
        if not ok then
            return nil, ngx.HTTP_INTERNAL_SERVER_ERROR, "failed Redis set" .. err
        end

        local exptime = self.redis_exptime
        red:expire(key,exptime)

        local logargs = args
        if logargs ~= "" then logargs = "?" .. args end

        local logArr = {
            key = key,
            url = uri .. logargs, 
            exptime = exptime,
        }
        
        local ok, err = red:set(key .. "_bottomData", value)
        if not ok then
            return nil, ngx.HTTP_INTERNAL_SERVER_ERROR, "failed Redis set bottomData" .. err
        end

        log(NOTICE, "Redis Cache Hit " .. cjson.encode(logArr))

        return value 

    -- status 返回非200
    elseif value and value.status < ngx.HTTP_INTERNAL_SERVER_ERROR then
        return nil, value.status, ""
    end

    -- 托底数据获取
    local value, err = red:get(key .. "_bottomData")
    if not value then
        return nil, ngx.HTTP_INTERNAL_SERVER_ERROR, "php timeout ".. self.proxy_timeout ..", failed Redis get bottomData"
    end

    log(NOTICE, "Get bottomData succ")
    self.X_Cache_hm = "His bot"
    return value
end


-- http Get 请求
-- return string 
function _M.httpGet(self, key, uri, args)

    local httpc = http.new()
    httpc:set_timeout(self.proxy_timeout)
    local res, err = httpc:request_uri(uri, {
        method = "get",
        query = args,
        headers = {["X-Skip-Fetch"] = "TRUE",} 
    })
    
    if not res then
        self.shmSet(self, key .. "_httpGet_error", 1, self.re_exptime)
    end
    return res
end


-- 添加header 信息
function _M.header(self, val)

    -- ngx.header.Server = 'HMWS/2.0';
    -- ngx.header.content_type = 'application/json; charset=utf-8';
    local val, err = ngx_re.split(val, "\r\n\r\n",nil,nil,2)
    ngx.header["X-Cache-hm"] = self.X_Cache_hm
    if val[1] then
        ngx.header['content_type'] = val[1] 
    end
    
    if not val[2] then
        return val
    end

    return val[2] 
end


return _M
