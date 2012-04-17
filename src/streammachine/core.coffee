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
        
    Stream: require "./stream"
    Rewind: require "./rewind_buffer"
        
    Sources:
        proxy:  require("./sources/proxy_room")
        
    Outputs:
        pumper:     require("./outputs/pumper")
        shoutcast:  require("./outputs/shoutcast")
        mp3:        require("./outputs/livemp3")
        sockets:    require("./outputs/sockets")
        
    #----------
        
    constructor: (options) ->
        @options = _u.defaults options||{}, @DefaultOptions
        
        @streams = {}
                
        # set up our core logger
        @log = new Logger name:"StreamMachine", streams: [
            { stream:process.stdout, level:'debug' },
            { path:@options.log, level:"debug" }
        ], serializers:
            req: Logger.stdSerializers.req
        
        @log.info("Instance initialized")
        
        # init our server
        @server = express.createServer()
        @server.use (req,res,next) => @streamRouter(req,res,next)
        @server.listen @options.listen
                
        @log.debug "caster is listening on port #{@options.listen}"
        
        # start up the socket manager
        @sockets = new @Outputs.sockets server:@server, core:@
        
        # should we be listening for slave servers?
        @slaves = new Core.Master @, @options.slaves if @options.slaves

    #----------
        
    # configure can be called on a new core, or it can be called to reconfigure 
    # an existing core.  we need to support either one.
    configure: (options) ->
        console.log "In configure with ", options

        # -- Sources -- #
        
        # are any of our current streams missing from the new options? if so, 
        # disconnect them
        for k,obj in @streams
            obj.disconnect() unless options.streams?[k]
            @streams.delete k
        
        # run through the streams we've been passed, initializing sources and 
        # creating rewind buffers
        for key,opts of options.streams
            console.log "stream for #{key}"
            if @streams[key]
                # existing stream...  pass it updated configuration
                @log.info opts:opts, "Passing updated config to source: #{key}"
                @streams[key].configure opts
            else
                @log.info opts:opts, "Starting up source: #{key}"
                @streams[key] = new @Stream @, key, @log.child(source:key), opts
                
        # FIXME: Need to update router to only have current streams
        
    #----------
    
    streamRouter: (req,res,next) ->
        # does the request match one of our streams?
        if m = ///^\/(#{_u(@streams).keys().join("|")})(?:\.mp3)?$///.exec req.url
            console.log "match is ", m[1]
            stream = @streams[ m[1] ]
            
            # -- Stream match! -- #
            if req.query.socket?
                # socket listener
                @sockets.addListener stream,req,res
                    
            else if req.query.off?
                # rewind to a starting offset
                new @Rewind.Listener stream, req, res, Number(req.query.off)
                    
            else if req.query.pump?
                # pump listener pushes from the buffer as fast as possible
                new @Outputs.pumper stream, req, res
                    
            else
                # normal live stream (with or without shoutcast)
                if req.headers['icy-metadata']?
                    # -- shoutcast listener -- #
                    new @Outputs.shoutcast stream, req, res
                else
                    # -- straight mp3 listener -- #
                    new @Outputs.mp3 stream, req, res
                
        else
            next()

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
    
    class @Master
        @DefaultOptions:
            port:       null
            password:   null
            
        constructor: (@core,opts) ->
            @options = _u.defaults opts||{}, @DefaultOptions
            
            if !@options.port || !@options.password
                @core.log.error("Invalid options for master server.  Must provide port and password.")
                return false
                
            # fire up a socket listener on our slave port
            @io = require("socket.io").listen @options.port
            
            # add our authentication
            @io.configure =>
                @io.set "authorization", (handshakeData,callback) =>
                    # look for password
                    console.log "handshake data is ", handshakeData
                    
                    if @options.password
                        # make sure we got the same password in the query
                        if @options.password == handshakeData.query?.password
                            callback null, true
                        else
                            callback "Invalid slave password.", false
                    else
                        callback null, true
            
            # look for slave connections    
            @io.on "connection", (sock) =>
                console.log "slave connection is #{sock.id}"
                
                # emit our configuration
                sock.emit("config",@core.options.streams)

    #----------
    
    class @Slave
        @DefaultOptions:
            server:     null
            password:   null
            
        constructor: (opts) ->
            @options = _u.defaults opts||{}, @DefaultOptions
            
            if !@options.server 
                @core.log.error "Invalid options for slave server. Must provide server."
                return false
                
            # connect to the master server
            @socket = require('socket.io-client').connect @options.server
            
            @socket.on "config", (config) =>
                console.log "got config of ", config
                
                # now create our own core with that stream config
                
