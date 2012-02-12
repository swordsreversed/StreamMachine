_u = require("underscore")
url = require('url')
http = require "http"


module.exports = class Core
    DefaultOptions:
        foo:        null
        streams:    {}
        
    DefaultStreamOptions:
        meta_interval:  10000
        name:           ""
        
    @Sources:
        proxy:  require("./sources/proxy_room")
        
    @Rewind:    require("./rewind_buffer")
    @Caster:    require("./outputs/caster")
    @Sockets:   require("./outputs/sockets")
        
    constructor: (options) ->
        @options = _u(_u({}).extend(@DefaultOptions)).extend( options || {} )
        
        @streams = {}
        
        # run through the streams we've been passed, initializing sources and 
        # creating rewind buffers
        for key,opts of @options.streams
            source = @createSource key, opts.source
            source.connect()
            
            rewind = new Core.Rewind source, opts.rewind
            
            @streams[key] = _u(_u({}).extend(@DefaultStreamOptions)).extend 
                source: source
                rewind: rewind
        
        # init our server
        @server = http.createServer (req,res) => @_handle(req,res)
        @server.listen(@options.listen)
        console.log "caster is listening on port #{@options.listen}"
        
        # start up the socket manager
        @sockets = new Core.Sockets server:@server, core:@
        
    #----------
    
    _handle: (req,res) ->
        requrl = url.parse(req.url,true)
        
        if m = (new RegExp("^\/(#{ _u(@streams).keys().join("|") })\.mp3")).exec requrl.pathname 
            console.log "matches stream #{m[1]}"
            stream = @streams[ m[1] ]
            
            if requrl.query.socket?
                # socket listener
                @sockets.addListener req,res,stream
                
            else if requrl.query.off?
                # rewind to offset
                offset = Number(requrl.query.off) || 1
                new Core.Rewind.Listener(req, res, stream.rewind, offset)
                
            else
                # normal live stream
                console.log "headers is ", req.headers
                icyMeta = if req.headers['icy-metadata']? then true else false

                if icyMeta
                    # -- create a shoutcast broadcaster instance -- #
                    new Core.Caster.Shoutcast req,res,stream

                else
                    # -- create a straight mp3 listener -- #
                    console.log "no icy-metadata requested...  straight mp3"
                    new Core.Caster.LiveMP3 req,res,stream
        else
            res.writeHead 404,
                "Content-Type": "text/plain"
                "Connection":   "close"
                
            res.end("Stream not found.")

    #----------
                
    createSource: (key,opts) ->
        # what type of source is this?
        if Core.Sources[ opts.type ]
            source = new Core.Sources[ opts.type ] key, opts
            return source
        else
            console.error "Invalid source type: #{opts.type}"
            process.exit(1)
            