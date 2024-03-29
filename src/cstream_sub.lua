#!/usr/local/openresty/luajit/bin/luajit-2.1.0-alpha

-- Synchronized click stream subscriber

package.path = '../lib/?.lua;../lib/?/?.lua;' .. package.path

require('zhelpers')

local cjson   = require('cjson.safe')
local cli     = require('cliargs')
local statsd  = require('statsd')({ host='127.0.0.1',
                                   port=8125,
                                   namespace='cstream.stats' })
local yaml    = require('yaml')
local zmq     = require('lzmq')

local _VERSION = '0.0.1'

cli:set_name('cstream_sub.lua')

cli:add_argument('ADDR', 'event stream publisher address')
cli:add_argument('PORT', 'event stream publisher base port')

cli:add_option('-s, --storage=TYPE',
               'storage engine type: [redis-server|mongodb]', 'redis')
cli:add_option('-p, --provider=NAME',
               "message parser type: [rutarget|testprovider]", 'rutarget')

cli:add_flag('-x, --dryrun', 'do not store clicks, just receive them')
cli:add_flag('-y, --sync', 'send sync request to publisher before subscribing')

cli:add_flag('-d, --debug', 'receiver will run in debug mode')
cli:add_flag('-v, --version', "prints the program's version and exits")

local args = cli:parse_args()
if not args then
  return
end

if args['v'] then
  return print('cstream_sub.lua: version ' .. _VERSION)
end

local provider
if (args['p'] ~= 'rutarget') and (args['p'] ~= 'testprovider') then
  return print('wrong message parser type, please see --help')
else
  provider = require('provider.' .. args['p'])
end

local storage
local storage_engine = args['s']
if (storage_engine == 'redis-server') or (storage_engine == 'mongodb') then
  storage = require('storage.' .. storage_engine)
else
  return print('wrong storage engine type, please see --help')
end

local dry_run = args['x']

local addr = args['ADDR']
local port = tonumber(args['PORT'])

local context = zmq.context()

local subscriber, err = context:socket{zmq.SUB,
                                       subscribe = '',
                                       connect = 'tcp://' .. addr .. ':' ..
                                         tostring(port)
}
zassert(subscriber, err)

if args['y'] then
  -- send sync request to publisher and wait for reply
  sleep(1)
  local syncclient = context:socket{zmq.REQ,
                                    connect = 'tcp://' .. addr .. ':' ..
                                      tostring(port+1)}
  zassert(syncclient, err)
  syncclient:send('') -- send a synchronization request
  syncclient:recv() -- wait for synchronization reply
  if args['d'] then printf("Synchronized\n") end
end

local client = storage.new()
if not client then
  return printf("error connecting to storage engine\n")
end

local msg_nbr = 0
local valid_nbr = 0

if args['d'] then printf("Waiting for incoming messages\n") end

while true do
  local msg = subscriber:recv()

  if args['d'] and (msg == "END") then break end

  local event, err = provider.parse_message(msg)
  local visitor = event.id

  if event then
    if not dry_run then
      client:save_event(event)
    end
    if args['d'] then
      print(yaml.dump(client:get_events(visitor)))
    end
    statsd:increment('clicks')
    valid_nbr = valid_nbr + 1
  end

  msg_nbr = msg_nbr + 1
end

if args['d'] then
  printf("Received %d messages, valid %d messages\n", msg_nbr, valid_nbr)
end
