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

        @client.once "ready", =>
            rFunc = =>
                @_connected = true
                @emit "connected", @client

                # see if there's a config to load
                @_config()

            if (@_db = Number(info.pathname.substr(1))) != NaN
                console.log "Redis connecting to DB #{@_db}"
                @client.select @_db, (err) =>
                    return @log.error "Redis DB select error: #{err}" if err

                    rFunc()
            else
                @_db = 0
                console.log "Redis using DB 0: #{info.pathname.substr(1)}"
                rFunc()


    #----------

    once_connected: (cb) ->
        if @_connected
            cb?(@client)
        else
            @once "connected", cb

    #----------

    _config: ->
        console.log "Querying config from Redis"
        @client.get "#{@options.key}:config", (err, reply) =>
            if reply
                config = JSON.parse(reply.toString())
                console.log "Got redis config of ", config
                @emit "config", config

     #----------

     _update: (config) ->
         @once_connected =>
             console.log "Saving configuration to Redis"

             @client.set "#{@options.key}:config", JSON.stringify(config), (err,reply) =>
                if err
                    console.log "Redis: Failed to save updated config: #{err}"
                else
                    console.log "Set config to #{@options.key}:streams", config, reply
