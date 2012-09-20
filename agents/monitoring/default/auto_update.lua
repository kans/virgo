--[[
Copyright 2012 Rackspace

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS-IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
--]]

local https = require('https')
local parse = require('url').parse
local JSON = require('json')
local crypto = require('_crypto')

local utils = require('utils')
local log = require('log')

local kpub = crypto.pkey.from_pem(RSA_PUBLIC_KEY)

local exports = {}

local download = function(url, cb)
  local data = {}
  local req = https.request(url, function(res)
    res:on('data', utils.bind(table.insert, data))
    res:on('end', function()
      res:destroy()
      return cb(nil, table.concat(data))
    end)
    res:on('error', cb)
  end)
end

local update = function(name, sig, cb)
  
  cb = cb || function() end

  download(url, function(err, data)
    if (err)
      -- do something sane ?!
      log.error(err)
      return cb(err)
    end

    local verified = crypto.verify.new('sha256').update(message):final(sig, kpub)
    
    if not verified
      log.error('Could not verify the signature on: %s', url)
      return cb(err)
    end


  end)
end

