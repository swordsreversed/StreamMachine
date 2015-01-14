_u      = require 'underscore'
Redis   = require 'redis'
Url     = require "url"
nconf   = require "nconf"

module.exports = class RedisManager extends require('events').EventEmitter
    DefaultOptions:
        server: "redis://localhost:6379"
        key:    "StreamMachine"

    constructor: (opts) ->
        @options = _u.defaults nconf.get("redis"), @DefaultOptions
        #@options = _u.defaults opts||{}, @DefaultOptions

        console.log "init redis with ", @options.server
        info = Url.parse @options.server
        @client = Redis.createClient info.port, info.hostname

        @client.once "ready", =>
            rFunc = =>
                @_connected = true
                @emit "connected", @client

                # see if there's a config to load
                #@_config()

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

    prefixedKey: (key) ->
        if @options.key
            "#{@options.key}:#{key}"
        else
            key

    #----------

    once_connected: (cb) ->
        if @_connected
            cb?(@client)
        else
            @once "connected", cb