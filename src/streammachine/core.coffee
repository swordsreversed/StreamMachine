_u = require("underscore")
url = require('url')
http = require "http"
connect = require("connect")


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
        
        # run through the streams we've been passed, initializing sources and 
        # creating rewind buffers
        for key,opts of @options.streams
            source = @createSource key, opts.source
            source.connect()
            
            rewind = new Core.Rewind source, opts.rewind
            
            @streams[key] = _u(_u(_u({}).extend(@DefaultStreamOptions)).extend( opts )).extend 
                source: source
                rewind: rewind
        
        # init our server
        @server = connect connect.query(),
            require("connect-assets")(),
            connect.router (app) => @_router(app)
            
        @server.listen @options.listen
        
        #@server = http.createServer (req,res) => @_handle(req,res)
        #@server.listen(@options.listen)
        console.log "caster is listening on port #{@options.listen}"
        
        # start up the socket manager
        @sockets = new Core.Outputs.sockets server:@server, core:@
        
    #----------
    
    _router: (app) ->                
        # -- register a route for each of our streams -- #
        _u(@streams).each (stream,key) =>
            app.get "/#{key}.mp3", (req,res,next) =>
                if req.query.socket?
                    # socket listener
                    @sockets.addListener req,res,stream
                    
                else if req.query.off?
                    # rewind to a starting offset
                    new Core.Rewind.Listener req, res, stream.rewind, Number(req.query.off)
                    
                else if req.query.pump?
                    # pump listener pushes from the buffer as fast as possible
                    new Core.Outputs.pumper req, res, stream
                    
                else
                    # normal live stream (with or without shoutcast)
                    if req.headers['icy-metadata']?
                        # -- shoutcast listener -- #
                        new Core.Outputs.shoutcast req, res, stream
                    else
                        # -- straight mp3 listener -- #
                        new Core.Outputs.mp3 req, res, stream
                        
        # -- register route for web player -- #
        #app.get "/"
    
    #----------
                
    createSource: (key,opts) ->
        # what type of source is this?
        if Core.Sources[ opts.type ]
            source = new Core.Sources[ opts.type ] key, opts
            return source
        else
            console.error "Invalid source type: #{opts.type}"
            process.exit(1)
            