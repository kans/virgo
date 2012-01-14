local FS = require('fs')
local JSON = require('json')

local path = '../../agents/monitoring/lua'
local AgentProtocol = require(path .. '/agent-protocol')
local AgentProtocolConnection = require(path .. '/agent-protocol-connection')

exports = {}

exports['test_handshake_hello'] = function(test, asserts)
  FS.read_file("tests/agent-protocol/handshake.hello.request.json", function (err, data)
    if (err) then error(err) end
    local hello = { }
    hello.data = JSON.parse(data)
    hello.write = function(_, res)
      hello.res = res
    end
    local agent = AgentProtocol.new(hello.data, hello)
    agent:request(hello.data)
    response = JSON.parse(hello.res)

    -- TODO: asserts.object_equals in bourbon
    asserts.equals(response.v, 1)
    asserts.equals(response.id, 1)
    asserts.equals(response.source, "endpoint")
    asserts.equals(response.target, "X")
    asserts.equals(response.result, nil)

    test.done()
  end)
end


return exports