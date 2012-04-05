_u = require("underscore")
url = require('url')
http = require "http"
express = require "express"
Logger = require "bunyan"


module.exports = class Core
    DefaultOptions:
        foo:        null
        streams:    {}
        
    DefaultStreamOptions:
        meta_interval:  10000
        name:           ""
        
    @Rewind: require("./rewind_buffer")
        
    @Sources:
        proxy:  require("./sources/proxy_room")
        
    @Outputs:
        pumper:     require("./outputs/pumper")
        shoutcast:  require("./outputs/shoutcast")
        mp3:        require("./outputs/livemp3")
        sockets:    require("./outputs/sockets")
        
    constructor: (options) ->
        @options = _u(_u({}).extend(@DefaultOptions)).extend( options || {} )
        
        @streams = {}
        
        # set up our core logger
        @log = new Logger name:"StreamMachine", streams: [
            { stream:process.stdout, level:'debug' },
            { path:options.log, level:"debug" }
        ], serializers:
            req: Logger.stdSerializers.req
        
        @log.info("Instance initialized")
        
        # run through the streams we've been passed, initializing sources and 
        # creating rewind buffers
        for key,opts of @options.streams
            @log.info opts:opts, "Starting up source: #{key}"
            @streams[key] = new Core.Stream key, @log.child(source:key), opts
        
        # init our server
        @server = express.createServer()
        @_router(@server)
        @server.listen @options.listen
        
        @log.debug "caster is listening on port #{@options.listen}"
        
        # start up the socket manager
        @sockets = new Core.Outputs.sockets server:@server, core:@
        
    #----------
    
    _router: (app) ->                
        # -- register a route for each of our streams -- #
        _u(@streams).each (stream,key) =>
            app.get "/#{key}(?:\.mp3)?", (req,res,next) =>
                if req.query.socket?
                    # socket listener
                    @sockets.addListener stream,req,res
                    
                else if req.query.off?
                    # rewind to a starting offset
                    new Core.Rewind.Listener stream, req, res, Number(req.query.off)
                    
                else if req.query.pump?
                    # pump listener pushes from the buffer as fast as possible
                    new Core.Outputs.pumper stream, req, res
                    
                else
                    # normal live stream (with or without shoutcast)
                    if req.headers['icy-metadata']?
                        # -- shoutcast listener -- #
                        new Core.Outputs.shoutcast stream, req, res
                    else
                        # -- straight mp3 listener -- #
                        new Core.Outputs.mp3 stream, req, res
                        
        # -- register route for web player -- #
        #app.get "/"
    
    #----------
                
    createSource: (key,log,opts) ->
        # what type of source is this?
        if Core.Sources[ opts.type ]
            source = new Core.Sources[ opts.type ] key, log, opts
            return source
        else
            console.error "Invalid source type: #{opts.type}"
            process.exit(1)
    
    #----------
            
    class @Stream
        @DefaultOptions:
            meta_interval:  10000
            name:           ""
            type:           null
        
        constructor: (key,log,opts) ->
            @options = _u.defaults opts||{}, @DefaultOptions
            
            @log = log
            @key = key
            
            @listeners = 0
            
            # make sure our source is valid
            if Core.Sources[ opts.source?.type ]
                @source = new Core.Sources[ opts.source?.type ] @, key, opts.source
            else
                @log.error opts:opts, "Invalid source type."
                return false
            
            # connect!
            @source.connect()
            
            # set up a rewind buffer
            @rewind = new Core.Rewind @, opts.rewind
        
        #----------
            
        registerListener: (listen) ->
            # increment our listener count
            @listeners += 1
            
            # log the connection start
            @log.debug req:listen.req, listeners:@listeners, "Connection start"
            
        closeListener: (listen) ->
            # decrement listener count
            @listeners -= 1
            
            # log the connection end
            @log.debug req:listen.req, listeners:@listeners, "Connection end"
            