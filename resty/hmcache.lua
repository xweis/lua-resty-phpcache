-- Copyright (C) Huo Mao (@)
-- 访问php 数据保存到redis和ngxcache 
-- php timeout 10s 
-- 如果超时访问托底数据，1分钟后再请求php 
 

local redis = require "resty.redis_iresty" 
local resty_lock = require "resty.lock"
local cjson = require "cjson"
--local http = require "resty.http"
--local ngx_re = require "ngx.re"
--local red = redis:new({host='10.0.0.17',auth='HCeNPa109XzzfqpC'})
local red = redis:new({host='127.0.0.1', auth=nil, timeout=5})
local setmetatable = setmetatable
--local key = ngx.var.escaped_key

local _M = { _VERSION = '1.0' }
local mt = { __index = _M }

local ERR = ngx.ERR
local NOTICE = ngx.NOTICE
local log = ngx.log

function _M.new()
    
    local ngxCache = ngx.shared.ngxCache
    if not ngxCache then
        return nil, "dictionary not found"
    end

    -- nginx 缓存时间
    local ngx_exptime = 1
    -- redis 缓存时间
    local redis_exptime = ngx.var.redis_exptime or 10
    -- header 标记缓存信息
    local X_Cache_hm = "miss" 
    local lockName = "lock"
    local bottomData_exptime = ngx.var.bottomData_exptime or 86400
    local ngx_debug = ngx.var.ngx_debug or false

    local self = {
        ngxCache = ngxCache,
        ngx_exptime = ngx_exptime,
        redis_exptime = redis_exptime,
        X_Cache_hm = X_Cache_hm, 
        lockName = lockName,
        bottomData_exptime = bottomData_exptime,
        ngx_debug = ngx_debug,
    }
    return setmetatable(self, mt)
end


-- ngx内部缓存 get
function _M.shmGet(self, key)
    
    local val, err = self.ngxCache:get(key)
    if val then
        self.X_Cache_hm = "His shm"
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
    local val, err = self.ngxCache:set(key, value, exptime)
    if val then
        return val
    end
    
    if err then return nil, "failed to get key from ngxCache : " .. err end

    return nil, "'" .. key .. "' cache Key not exist"

end


function _M.get(self,key)

    -- 获取ngxcache数据
    local val, err  = self.shmGet(self, key)
    if val then
        return self.header(self,val)
    end

    -- 创建锁 
    local lock, err = resty_lock:new(self.lockName)
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


    -- Redis 没有数据,php后端获取
    local val, redErr = self.fetch_redis(self, key)
    if not val then
        local ok, err = lock:unlock()
        if not ok then
            return nil, "failed to unlock: " .. err
        end

        -- php redis 挂掉,且获取托底数据失败 | status 非200 
        return nil, redErr 
    end


    -- 用新获取的值更新ngxcache缓存 
    local ok, shmerr = self.shmSet(self, key, val, self.ngx_exptime)
    if not ok then
        local ok, err = lock:unlock()
        if not ok then
            return nil, "failed to unlock: " .. err
        end

        return nil, "failed to update shm cache: " .. shmerr 
    end

    local ok, err = lock:unlock()
    if not ok then
        return nil, "failed to unlock: " .. err
    end

    return self.header(self,val)
end


-- 保存redis数据，并创建托底数据
-- return string 
function _M.fetch_redis(self, key)

    local value,err = red:get(key)
    if value then
        self.X_Cache_hm = "His"
        return value
    end

    -- 子请求访问
    ngx.req.set_header("X-Skip", "TRUE")
    --ngx.req.clear_header("Accept-Encoding")
    value = ngx.location.capture(ngx.var.request_uri)

    local httpStatus = nil
    if value then 
        -- status  200
        httpStatus = tonumber(value.status)
        if httpStatus == ngx.HTTP_OK then

            --清除 set-cookie
            local removeKey = {}
            for k,v in pairs(value.header) do
                if ngx.re.find(k, "set-cookie", "ijo") then
                    table.insert(removeKey,k)
                end
            end
            for k,v in pairs(removeKey) do
                if v then
                    value.header[v] = nil
                end
            end

            value = cjson.encode(value) 
            --set redis
            local ok, err = red:set(key, value)
            if not ok then
                return nil, "failed Redis set" .. err
            end
            red:expire(key,self.redis_exptime)

            --set redis 托底数据
            local ok, err = red:set(key .. "_bottomData", value)
            if not ok then
                return nil, "failed Redis set bottomData" .. err
            end
            red:expire(key .. "_bottomData", self.bottomData_exptime)

            self.log(self, NOTICE, "Redis Cache Hit " .. ngx.var.host .. ngx.var.request_uri)

            return value 
        end

        -- status 30x 40x
        local statusList = {
            [301] = 1,
            [302] = 1,
            [404] = 1,
        }
        if statusList[httpStatus] then
            return cjson.encode(value) 
        end
    end


    -- status 500 获取托底数据
    local value, err = red:get(key .. "_bottomData")
    if not value then
        return nil, "failed Redis get bottomData"
    end

    self.log(self, NOTICE, "Get bottomData succ" .. ngx.var.host .. ngx.var.request_uri)
    self.X_Cache_hm = "His bot"
    return value
end


-- 添加header 信息
function _M.header(self, val)

    local value = cjson.decode(val)
    for k,v in pairs(value.header) do
        ngx.header[k] = v
    end
    ngx.header["X-Cache-hm"] = self.X_Cache_hm

    return value
end


-- log
function _M.log(self,loglevel,msg)
    if self.ngx_debug then
        log(loglevel,msg)
    end
    return 
end

return _M
