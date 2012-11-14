_u = require "underscore"

Logger = require "../log_controller"
Stream = require "./stream"
Server = require "./server"

module.exports = class Slave extends require("events").EventEmitter
    DefaultOptions:
        foo: "bar"
        max_zombie_life:    1000 * 60 * 60
        
    Outputs:
        pumper:     require("../outputs/pumper")
        shoutcast:  require("../outputs/shoutcast")
        mp3:        require("../outputs/livemp3")
        sockets:    require("../outputs/sockets")
        
    constructor: (opts) ->
        @options = _u.defaults opts||{}, @DefaultOptions
        
        @streams = {}
        @root_route = null
            
        # -- Set up logging -- #
        
        @log = @options.logger
            
        # -- Make sure we have the proper slave config options -- #
            
        if @options.slave?.master 
            # -- connect to the master server -- #
            
            @log.debug "Connecting to master at ", master:@options.slave.master
            
            @master = require('socket.io-client').connect @options.slave.master
            
            @master.on "connect", =>
                # connect up our logging proxy
                @log.debug "Connected to master."
                @log.proxyToMaster @master
            
            @master.on "config", (config) =>
                console.log "got config of ", config
                @configureStreams config
                                            
        # -- set up our stream server -- #
            
        # init our server
        @server = new Server core:@
        @server.listen @options.listen
            
        @log.debug "Slave is listening on port #{@options.listen}"
        
        # start up the socket manager on the listener
        #@sockets = new @Outputs.sockets server:@server.server, core:@
        
        # -- Listener Counts -- #
        
        # once each minute, count all listeners and send them on to the master
        
        @_listeners_interval = setInterval =>
            counts = {}
            total = 0
            
            for k,s of @streams
                l = s.listeners()
                counts[k] = l
                total += l

            @log.debug "sending listeners: #{total}", counts
            @master?.emit "listeners", counts:counts, total:total

        , 30 * 1000
                            
        # -- Graceful Shutdown -- #
        
        # attach a USR2 handler that causes us to stop listening. this is 
        # used to allow a new server to start up
        process.on "SIGTERM", =>
            @log.debug "Got SIGTERM in core...  Starting shutdown"
            
            # stop accepting new connections
            @server?.stopListening()
            
            # when should we get pushy?
            @_shutdownMaxTime = (new Date).getTime() + @options.max_zombie_life
            
            # need to start a process to quit when existing connections disconnect
            @_shutdownTimeout = setInterval =>
               # have we used up the grace period yet?
               force_shut = if (new Date).getTime() > @_shutdownMaxTime then true else false
                
               # build a listener count for all streams
               listeners = 0
               for k,stream of @streams
                   slisteners = stream.countListeners()
                    
                   if slisteners == 0 || force_shut
                       # if everyone's done (or we're feeling pushy), disconnect
                       stream.disconnect()
                   else
                       listeners += slisteners
                    
               if listeners == 0
                   # everyone's out...  go ahead and shut down
                   @log.debug "Shutdown complete", => process.exit()
               else
                   @log.debug "Still awaiting shutdown; #{listeners} listeners"
                
            , 60 * 1000
    
    #----------
           
    configureStreams: (options) ->
        @log.debug "In configure with ", options:options

        # -- Sources -- #
        
        # are any of our current streams missing from the new options? if so, 
        # disconnect them
        for k,obj in @streams
            console.log "calling disconnect on ", k
            obj.disconnect() unless options?[k]
            @streams.delete k
        
        # run through the streams we've been passed, initializing sources and 
        # creating rewind buffers
        for key,opts of options?.streams
            console.log "stream for #{key}"
            if @streams[key]
                # existing stream...  pass it updated configuration
                @log.debug "Passing updated config to source: #{key}", opts:opts
                @streams[key].configure opts
            else
                @log.debug "Starting up source: #{key}", opts:opts
                
                slog = @log.child stream:key
                @streams[key] = new Stream @, key, slog, opts
                
                if @master
                    source = new Slave.SocketSource master:@master, key:key, log:slog
                    @streams[key].useSource(source)
                
            # should this stream accept requests to /?
            if opts.root_route
                @root_route = key
    
    #----------
    
    # emulate a source connection, receiving data via sockets from our master server
                
    class @SocketSource extends require("events").EventEmitter
        constructor: (opts) ->
            @master = opts.master
            @key = opts.key
            @log = opts.log
            
            #@io = @master.of "stream:#{@key}"
            
            @log.debug "created SocketSource for #{@key}"
            
            @master.on "streamdata:#{@key}",    (chunk) => @emit "data", chunk
            @master.on "streammeta:#{@key}",    (chunk) => @emit 'metadata', chunk
            
        disconnect: ->
            console.log "SocketSource disconnect for #{key} called"
        