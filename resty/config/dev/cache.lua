-- config.lua

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
