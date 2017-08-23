-- config.lua

local cList = {
    ["^/$"] = 30,
    ["^/channel/all$"] = 30,
    ["^/(\\d+)$"] = 10,
    ["^/(.*).json$"] = 10,
    ["^/(.*).html$"] = 10,
}

return cList
