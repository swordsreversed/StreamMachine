_u = require 'underscore'
Redis = require 'redis'
Url = require "url"
EventEmitter = require('events').EventEmitter

module.exports = class RedisConfig extends EventEmitter
    DefaultOptions:
        server: "redis://localhost:6379"
        key:    "StreamMachine"
    
    constructor: (opts) ->
        @options = _u.defaults opts||{}, @DefaultOptions
        
        console.log "init redis with ", @options.server
        info = Url.parse @options.server
        @client = Redis.createClient info.port, info.hostname
        
        @client.on "connect", =>
            # see if there's a config to load
            console.log "Querying config from Redis"
            @client.get "#{@options.key}:streams", (err, reply) =>
                if reply
                    streams = JSON.parse(reply.toString())
                    console.log "Got redis config of ", streams
                    @emit "config", streams
            
            # now go into PUB/SUB mode and subscribe for config updates
            @client.on "message", (channel,message) => 
                if message
                    streams = JSON.parse(message.toString())
                    console.log "Got redis config of ", streams
                    @emit "config", streams
                    
            @client.subscribe @options.key
            
    _config: ->
        console.log "Querying config from Redis"
        @client.get "#{@options.key}:streams", (err, reply) =>
            if reply
                streams = JSON.parse(reply.toString())
                console.log "Got redis config of ", streams
                @emit "config", streams
                    
            
        
    