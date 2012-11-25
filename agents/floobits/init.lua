local net = require('net')
local json = require('json')
local parse = require('url').parse
local LineEmitter = require('line-emitter').LineEmitter

local exports = {}

process:on('error', function(err)
  p(err)
end)

local function create_connection()
  --local conn = net.createConnection(3148, "127.0.0.1", function(err)
  local conn = net.createConnection(3148, "192.168.1.146", function(err)
    if err then return error(err) end;
  end)
  return conn
end

local clients = {}

local function server_listener(client)
  print('hawro')
  -- local conn = create_connection()
  local le = LineEmitter:new()
  local handshake_complete = false
  local uid
  client:write('hawro')
  le:on('data', function(d)
    print(d)
    -- if handshake_complete then
    --   return conn:write(d..'\n')
    -- end

    -- local handshake = json.parse(d)
    -- uid = handshake.uid

    -- if not uid then
    --   print('no uid. killing client')
    --   return client:destroy()
    -- end

    -- if clients[uid] then
    --   print('destroying existing client')
    --   clients[uid]:destroy()
    -- end

    -- clients[uid] = client

    -- handshake_complete = true
  end)

  client:pipe(le)

  client:on('close', function()
    print('client close')
  end)

  client:on('end', function()
    print('client ended')
    if uid then
      clients[uid] = nil
    end
  end)

  -- conn:pipe(client)
  -- conn:on('close', function()
  --   print('close')
  --   conn = create_connection()
  -- end)
  -- conn:on('end', function()
  --   print('end')
  -- end)

  -- conn:on('finished', function()
  --   print('finished')
  -- end)
end

local function create_server()
  print('starting')
  local server = net.createServer(server_listener):listen(4567)
  server:on('error', function(err)
    p('err', err)
  end)
end

exports.run = function(argvs)
  create_server()
end

return exports
