_u = require 'underscore'
Redis = require 'redis'
Url = require "url"
EventEmitter = require('events').EventEmitter

module.exports = class RedisConfig extends EventEmitter
    constructor: (@redis) ->
        @_config()

    #----------

    _config: ->
        @redis.once_connected (client) =>
            console.log "Querying config from Redis"
            client.get @redis.prefixedKey("config"), (err, reply) =>
                if reply
                    config = JSON.parse(reply.toString())
                    console.log "Got redis config of ", config
                    @emit "config", config

     #----------

     _update: (config) ->
         @redis.once_connected (client) =>
             console.log "Saving configuration to Redis"

             client.set @redis.prefixedKey("config"), JSON.stringify(config), (err,reply) =>
                if err
                    console.log "Redis: Failed to save updated config: #{err}"
                else
                    console.log "Set config to ", config, reply
