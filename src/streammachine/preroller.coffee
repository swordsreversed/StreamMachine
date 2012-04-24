_u = require "underscore"
http = require "http"

module.exports = class Preroller
    DefaultOptions:
        server:     null
        path:       "/p"
        
    constructor: (@stream,@key,opts) ->
        @options = _u.defaults opts||{}, @DefaultOptions
        
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

        # -- make a request to the preroll server -- #
        
        opts = 
            host:       @options.server
            path:       [@options.path,@key,@stream_key].join("/")
        
        req = http.get opts, (rres) =>
            if rres.statusCode == 200
                # stream preroll through to the output
                rres.on "data", (chunk) =>
                    res.write(chunk)

                # when preroll is done, call the output's callback
                rres.on "end", =>
                    cb?()
                    return true
                    
            else
                cb?()
                return true
    
    #----------
    
    connect: ->
        
        
    #----------
    
    disconnect: ->
        
    #----------