-- cache.lua

local cList = {
    ['www.test.com'] = {
        ["^/$"] = 30,
        ["^/(\\d+)$"] = 120,
        ["(.*)(.json|.html|.xml|.shtml)$"] = 600,
    },
}

return cList
