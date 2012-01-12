{EventEmitter}  = require "events"
Streamer        = require "./streamer"
ControlRoom     = require "./control_room"
ProxyRoom       = require "./proxy_room"

module.exports = class Streamer extends EventEmitter
    constructor: (@configuration) ->
        @streamer   = new Streamer @configuration
        @control    = new ControlRoom @configuration

    #----------
    
    start: ->
        return if @starting or @started
        @starting = true

        startServer = (server, port, callback) -> process.nextTick ->
            try
                server.on 'error', callback
                
                server.once 'listening', ->
                    server.removeListener 'error', callback
                    callback()
                    
                server.listen port
            catch err
                callback err
                
        pass = =>
            @starting = false
            @started = true
            @emit "smart"
            
        flunk = (err) =>
            @starting = false
            try @streamer.close()
            try @control.close()
            @emit "error", err
            
        {streamPort, controlPort} = @configuration
        startServer @streamer, streamPort, (err) =>
            if err then flunk err
            else startServer @control, controlPort, (err) =>
                if err then flunk err
                else pass()

    stop: =>
        return if @stopping or !@started
        @stopping = true
        
        stopServer = (server, callback) -> process.nextTick ->
            try
                close = ->
                    server.removeListener "close", close
                    callback null
                server.on "close", close
                server.close()
            catch err
                callback err
                
        stopServer @streamer, =>
            stopServer @control, =>
                @stopping = false
                @started = false
                @emit "stop"