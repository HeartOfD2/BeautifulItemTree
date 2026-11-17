-- Base locale. Keys ARE the English text; missing translations fall back to the key.
local _, ns = ...
local L = setmetatable({}, { __index = function(_, key) return key end })
ns.L = L
