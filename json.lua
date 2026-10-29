-- TotA Meter: a small JSON writer for the export file.
-- Tables with items 1..n are arrays and empty tables are empty arrays (the
-- export has no empty objects); other tables are objects with sorted keys.

local M = TotaMeter
local Json = {}
M.Json = Json

Json.ARRAY = setmetatable({}, { __tostring = function() return "[]" end })

local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function str(s)
  s = string.gsub(s, '[%c"\\]', function(c) return ESC[c] or string.format("\\u%04x", string.byte(c)) end)
  return '"' .. s .. '"'
end

local function num(n)
  if n ~= n or n == math.huge or n == -math.huge then return "null" end
  if n == math.floor(n) and math.abs(n) < 1e15 then return string.format("%d", n) end
  local s = string.format("%.4f", n)
  s = string.gsub(s, "0+$", "")
  return (string.gsub(s, "%.$", ""))
end

local function isArray(t)
  local n = #t
  if n == 0 then return false end
  local count = 0
  for _ in pairs(t) do count = count + 1 end
  return count == n
end

local encode = nil
encode = function(v, depth)
  if depth > 32 then error("JSON nesting too deep") end
  local tv = type(v)
  if v == nil then return "null" end
  if v == Json.ARRAY then return "[]" end
  if tv == "boolean" then return v and "true" or "false" end
  if tv == "number" then return num(v) end
  if tv == "string" then return str(v) end
  if tv ~= "table" then return "null" end
  if next(v) == nil then return "[]" end   -- the format has no empty objects
  local parts = {}
  if isArray(v) then
    for i = 1, #v do parts[i] = encode(v[i], depth + 1) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local keys = {}
  for k, x in pairs(v) do if type(k) == "string" and x ~= nil then keys[#keys + 1] = k end end
  table.sort(keys)
  for _, k in ipairs(keys) do parts[#parts + 1] = str(k) .. ":" .. encode(v[k], depth + 1) end
  return "{" .. table.concat(parts, ",") .. "}"
end

function Json.Encode(v) return encode(v, 0) end
