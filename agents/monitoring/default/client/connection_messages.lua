local bind = require('utils').bind
local timer = require('timer')
local Emitter = require('core').Emitter
local Object = require('core').Object
local misc = require('../util/misc')
local logging = require('logging')
local loggingUtil = require ('../util/logging')
local path = require('path')
local util = require('../util/misc')
local table = require('table')
local os = require('os')
local https = require('https')
local fs = require('fs')
local async = require('async')
local fmt = require('string').format
local fsutil = require('../util/fs')

-- Connection Messages

local ConnectionMessages = Emitter:extend()
function ConnectionMessages:initialize(connectionStream)
  self._connectionStream = connectionStream
  self:on('handshake_success', bind(ConnectionMessages.onHandshake, self))
  self:on('client_end', bind(ConnectionMessages.onClientEnd, self))
  self:on('message', bind(ConnectionMessages.onMessage, self))
  self._lastFetchTime = 0
end

function ConnectionMessages:getStream()
  return self._connectionStream
end

function ConnectionMessages:onClientEnd(client)
  client:log(logging.INFO, 'Detected client disconnect')
end

function ConnectionMessages:onHandshake(client, data)
  -- Only retrieve manifest if agent is bound to an entity
  if data.entity_id then
    self:fetchManifest(client)
  else
    client:log(logging.DEBUG, 'Not retrieving check manifest, because ' ..
                              'agent is not bound to an entity')
  end
end

function ConnectionMessages:fetchManifest(client)
  function run()
    if client then
      client:log(logging.DEBUG, 'Retrieving check manifest...')

      client.protocol:request('check_schedule.get', function(err, resp)
        if err then
          -- TODO Abort connection?
          client:log(logging.ERROR, 'Error while retrieving manifest: ' .. err.message)
        else
          client:scheduleManifest(resp.result)
        end
      end)
    end
  end

  if self._lastFetchTime == 0 then
    if self._timer then
      timer.clearTimer(self._timer)
    end
    self._timer = process.nextTick(run)
    self._lastFetchTime = os.time()
  end
end

function ConnectionMessages:httpGet(client, path, file_path, retries, cb)
  -- Does a HTTP GET over to the clients endpoint streaming the body to file_path attempting
  -- retries number of times

  local function ensure_retries(err, ...)
    if not err then return cb(nil, ...) end

    if retries >= 0 then
      client:log(logging.INFO, 'retrying download')
      return self:httpGet(client, path, file_path, retries-1, cb)
    end
    cb(err)
  end

  local function _get()
    local stream = fs.createWriteStream(file_path)
    
    local options = {
      host = client._host,
      port = client._port,
      path = path,
      method = 'GET'
    }

    util.merge(options, client._tls_options)
    
    local req = https.request(options, function(res)
      stream:on('error', ensure_retries)
      stream:on('end', ensure_retries)
      res:pipe(stream)
      res:on('end', function(d)
        stream:finish(d)
      end)
    end)
    req:on('error', ensure_retries)
    req:done()
  end

  status, err = pcall(_get)
  if err then ensure_retries(err) end
end

function ConnectionMessages:getUpdate(update_type, client)
  local dir, filename

  if update_type == "binary" then
    dir = virgo_paths.get(virgo_paths.VIRGO_PATH_TMP_DIR)
    filename = virgo.default_name
  elseif update_type == "bundle" then 
    dir = virgo_paths.get(virgo_paths.VIRGO_PATH_BUNDLE_DIR)
    filename = virgo.default_name .. '.zip'
  else
    return client:log(logging.WARNING, fmt('Got request for %s update.', update_type))
  end

  local file_path = path.join(dir, filename)

  async.waterfall({
    function(cb)
      fsutil.mkdirp(dir, "0755", function(err)
        if not err then return cb() end
        if err.code == "EEXIST" then return cb() end
        cb(err)
      end)
    end,
    function(cb)
      client.protocol:request(update_type ..'_update.get_version', cb)
    end,
    function(res, cb)
      local version = res.result.version
      local uri_path = fmt('/update/%s/%s', update_type, res.result.version)
      
      client:log(logging.INFO, fmt('fetching version %s and its sig for %s', version, update_type))

      async.parallel({
        function(cb)
          self:httpGet(client, uri_path, file_path, 1, cb)
        end,
        function(cb)
          self:httpGet(client, uri_path..'.sig', file_path..'.sig', 1, cb)
        end
      }, cb)
    end
  }, function(err, res)
    if err then
      if type(err) == 'table' then 
        err = table.concat(err, '\n')
      end
      return client:log(logging.ERROR, 'error downloading update ' .. err)
    end

    client:log(logging.INFO, 'downloaded update')
  end)
  
end

function ConnectionMessages:onMessage(client, msg)

  local method = msg.method

  if not method then
    client:log(logging.WARNING, fmt('no method on message!'))
    return
  end

  client:log(logging.DEBUG, fmt('received %s', method))

  local cb = function(err, msg)
    if (err) then
      self:emit('error', err)
      client:log(logging.INFO, fmt('error handling %s %s', method, err))
      return
    end

    if method == 'check_schedule.changed' then
      self._lastFetchTime =   0
      client:log(logging.DEBUG, 'fetching manifest')
      self:fetchManifest(client)
      return
    end

    local update = nil
    if method == 'binary_update.available' then
      update = 'binary'
    elseif method == 'bundle_update.available' then
      update = 'bundle'
    end

    if update then 
      return self:getUpdate(update, client) 
    end

    client:log(logging.DEBUG, fmt('No handler for method: %s', method))
  end

  client.protocol:respond(method, msg, cb)
end

local exports = {}
exports.ConnectionMessages = ConnectionMessages
return exports
