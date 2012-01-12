_u = require '../lib/underscore'
{EventEmitter}  = require "events"
http = require "http"
icecast = require("icecast-stack")

module.exports = class Caster extends EventEmitter
    DefaultOptions:
        source:         null
        port:           8080
        meta_interval:  10000
        name:           "Caster"
        title:          "Welcome to Caster"
    
    #----------
    
    constructor: (options) ->
        @options = _u(_u({}).extend(@DefaultOptions)).extend( options || {} )

        if !@options.source
            console.error "No source for broadcast!"
            
        # attach to source
        @source = @options.source
                    
        # set up shoutcast listener
        @server = http.createServer (req,res) => @_handle(req,res)
        @server.listen(@options.port)
        console.log "caster is listening on port #{@options.port}"
        
    #----------    
            
    _handle: (req,res) ->
        console.log "in _handle for caster request"
        icyMeta = if req.headers['icy-metadata'] == 1 then true else false
        
        if req.url == "/shoutcast.mp3"
            headers = 
                "Content-Type":         "audio/mpeg"
                "Connection":           "close"
                "Transfer-Encoding":    "identity"
            
            if icyMeta
                # convert this into an icecast response
                res = new icecast.IcecastWriteStack res, @options.meta_interval
                res.queueMetadata StreamTitle:"Welcome to Caster", StreamURL:""
                
                # add icy headers
                headers['icy-name'] = @options.name
                headers['icy-metaint'] = @options.meta_interval
                                
                @source.on "metadata", (data) -> 
                    if data.streamTitle
                        res.queueMetadata data      
                        
            # write out our headers
            res.writeHead 200, headers                  

            # and start sending data...
            @source.on "data", (chunk) ->
                res.write(chunk)
        else
            res.write "Nope..."
            
        req.connection.on "close", ->
            
            
            
            
    #----------