_u = require "underscore"
http = require "http"

module.exports = class Preroller
    DefaultOptions:
        server:     null
        path:       "/p"
        
    constructor: (@stream,@key,opts) ->
        @options = _u.defaults opts||{}, @DefaultOptions
        
        @_counter = 1
        
        if !@options.server
            @stream.log.error("Cannot connect to preroll without a server")
            return false
        
        # -- need to look at the stream to get characteristics -- #
        
        console.log "calling get_stream_key"
        @stream.source?.get_stream_key (key) =>
            @stream_key = key
            @stream.log.debug "Stream key is #{@stream_key}"
        
    #----------
    
    pump: (res,cb) ->
        # short-circuit if we haven't gotten a stream key yet
        if !@stream_key
            cb?()
            return true

        count = @_counter++

        # -- make a request to the preroll server -- #
        
        opts = 
            host:       @options.server
            path:       [@options.path,@key,@stream_key].join("/")
        
        conn = res.stream?.connection || res.connection
                
        console.log "firing preroll request", count
        req = http.get opts, (rres) =>
            console.log "got preroll response ", count
            if rres.statusCode == 200
                # stream preroll through to the output
                rres.on "data", (chunk) =>
                    res.write(chunk)

                # when preroll is done, call the output's callback
                rres.on "end", =>
                    conn.removeListener "close", conn_pre_abort
                    conn.removeListener "end", conn_pre_abort
                    cb?()
                    return true
                    
            else
                conn.removeListener "close", conn_pre_abort
                conn.removeListener "end", conn_pre_abort
                cb?()
                return true
                
        req.on "socket", (sock) =>
            console.log "socket granted for ", count
            
        req.on "error", (err) =>
            console.log "got a request error for ", count, err
            
        # attach a close listener to the response, to be fired if it gets 
        # shut down and we should abort the request

        conn_pre_abort = => 
            console.log "aborting preroll ", count
            req.abort()
        
        conn.once "close", conn_pre_abort
        conn.once "end", conn_pre_abort
        
    
    #----------
    
    connect: ->
        
        
    #----------
    
    disconnect: ->
        
    #----------