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
local crypto = require('_crypto')

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
function ConnectionMessages:verify(path, sig_path, kpub_path, cb)

  local parallel = {
    hash = function(cb)
      local hash = crypto.verify.new('sha256')
      local stream = fs.createReadStream(path)
      stream:on('data', function(d)
        hash:update(d)
      end)
      stream:on('end', function() 
        cb(nil, hash)
      end)
      stream:on('error', cb)
    end,
    sig = function(cb)
      fs.readFile(sig_path, cb)
    end,
    kpub = function(cb)
      fs.readFile(kpub_path, function(err, data)
        if err then return cb(err) end
        return cb(nil, crypto.pkey.from_pem(data))
      end)
    end
  }
  async.parallel(parallel, function(err, res)
    if err then return cb(err) end
    local hash = res.hash[1]
    local sig = res.sig[1]
    local pub = res.kpub[1]
    if not hash:final(sig, pub) then
      return cb('invalid sig on file: '.. path)
    end
    cb()
  end)
end

function ConnectionMessages:getUpdate(update_type, client)
  local dir, filename, file_path, version, extension

  filename = virgo.default_name
  extension = ""

  local function get_path(arg)
    local sig = arg and arg.sig and '.sig' or ""
    local verified = arg and arg.verified

    local name = filename..'-'..version..extension..sig
    local _dir
    if verified then 
      _dir = dir
    else
      _dir = path.join(dir, 'unverified')
    end
    return path.join(_dir, name)
  end

  if update_type == "binary" then
    dir = virgo_paths.get(virgo_paths.VIRGO_PATH_TMP_DIR)
  elseif update_type == "bundle" then 
    dir = virgo_paths.get(virgo_paths.VIRGO_PATH_BUNDLE_DIR)
    extension = '.zip'
  else
    return client:log(logging.WARNING, fmt('Got request for %s update.', update_type))
  end

  unverified_dir = path.join(dir, 'unverified')

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
      version = res.result.version

      local uri_path = fmt('/update/%s/%s', update_type, version)
      
      client:log(logging.INFO, fmt('fetching version %s and its sig for %s', version, update_type))

      async.parallel({
        function(cb)
          self:httpGet(client, uri_path, get_path(), 1, cb)
        end,
        function(cb)
          self:httpGet(client, uri_path..'.sig', get_path{sig=true}, 1, cb)
        end
      }, cb)
    end,
    function(res, cb)
      client:log(logging.DEBUG, 'Downloaded update and sig')
      self:verify(get_path(), get_path{sig=true}, process.cwd()..'/tests/ca/server.pem', cb)
    end,
  function(cb)
    client:log(logging.INFO, 'verified update')

    async.parallel({
      function(cb) 
        fs.rename(get_path(), get_path{verified=true}, cb)
      end,
      function(cb)
        fs.rename(get_path{sig=true}, get_path{sig=true, verified=true}, cb)
      end
      }, cb)
  end}, 
  function(err, res)
    if err then
      if type(err) == 'table' then err = table.concat(err, '\n') end
      return client:log(logging.ERROR, 'downloading update => ' .. err)
    end
    client:log(logging.INFO, 'installed update, now go restart')
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
