local storage = {
  _VERSION     = '0.0.1',
  _DESCRIPTION = 'Click stream storage operations'
}

local cmsgpack = require('cmsgpack')
local redis    = require('redis')
local serpent  = require('serpent')
local crypto   = require('crypto')

local defaults = {
  host_port   = 'unix:/tmp/redis.sock',
  expire_time = 60*60*24*365 -- one year
}

local function merge_defaults(parameters)
  if parameters == nil then
    parameters = {}
  end
  for k, v in pairs(defaults) do
    if parameters[k] == nil then
      parameters[k] = defaults[k]
    end
  end
  return parameters
end

local function hex_to_binary(hex)
  return string.gsub(hex, '..', function(hexval)
    return string.char(tonumber(hexval, 16))
  end)
end

local function binary_to_hex(binary)
  return (string.gsub(binary, '.', function (b)
    return string.format('%02x', string.byte(b))
  end))
end

local client_prototype = {}

client_prototype.save_click = function(client, click)
  -- 'id'' key must present in click
  local id = click.id
  if not id then return false end

  local key = 'c=clicks:t=' .. id
  click.id = nil -- get rid of it, will store it in redis key

  -- compute sha1 hash of user agent string if 'ua' key exists in click,
  -- and then:
  --   - store ua sting in redis using its hex hash as a key
  --   - replace 'ua' in click with its binary hash
  local ua = click.ua
  if ua then
    client.sha1:reset()
    local ua_hash = client.sha1:final(ua) -- returns hex value
    local ua_data = hex_to_binary(ua_hash)
    client.redis:setnx('c=ua:h=' .. ua_hash, ua)
    click.ua = ua_data
  end

  local url = click.url
  if url then
    -- leave only domain name of the server in 'url'
    click.url = string.match(url, '^https*://([%w%.%-]+)/*')
  end

  assert(client.redis:lpush(key, cmsgpack.pack(click)))
  assert(client.redis:expire(key, client.expire_time))

  if math.random(1,100) == 1 then
    -- do list trimming roughly once per 100 saves
    assert(client.redis:ltrim(key, 0, 99))
  end

  return true
end

client_prototype.get_clicks = function(client, id)
  local key = 'c=clicks:t=' .. id
  local clicks = client.redis:lrange(key, 0, -1)
  local uas = {}
  local res = {}

  for i, c in ipairs(clicks) do
    res[i] = cmsgpack.unpack(c)

    -- restore ua string from hash table
    if res[i].ua then
      local hex_hash = binary_to_hex(res[i].ua)
      local ua_text

      if uas[hex_hash] then
        ua_text = uas[hex_hash]
      else
        ua_text = client.redis:get('c=ua:h=' .. hex_hash)
        uas[hex_hash] = ua_text
      end

      res[i].ua = ua_text
    end
  end

  return res
end

local function create_redis_client(parameters)
  local redis_client = redis.connect(parameters.host_port)
  return redis_client
end

local function create_client(proto, redis_client, parameters)
  local client = setmetatable({}, getmetatable(proto))

  for i, v in pairs(proto) do
    client[i] = v
  end

  client.redis = redis_client
  client.expire_time = parameters.expire_time
  client.sha1 = crypto.digest.new('sha1')
  return client
end

function storage.new(...)
  local args, parameters = {...}, nil

  if #args == 1 then
    if type(args[1]) == 'table' then
      parameters = args[1]
    end
  end

  math.randomseed(os.time())
  parameters = merge_defaults(parameters)
  local redis_client  = create_redis_client(parameters)
  local client = create_client(client_prototype, redis_client, parameters)
  return client
end

return storage
