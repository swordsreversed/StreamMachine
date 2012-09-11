_u = require("underscore")
url = require('url')
http = require "http"
express = require "express"
Logger = require "./log_controller"

module.exports = class Core
    DefaultOptions:
        streams:            {}
        # after a new deployment, allow a one hour grace period for 
        # connected listeners
        max_zombie_life:    1000 * 60 * 60
        
    Redis:  require "./redis_config"
    Stream: require "./stream"
    Rewind: require "./rewind_buffer"
    Preroller: require "./preroller"
    Server: require "./server"
    SourceIn: require "./source_in"
        
    Sources:
        proxy:      require("./sources/proxy_room")
        icecast:    require("./sources/icecast")
        
    Outputs:
        pumper:     require("./outputs/pumper")
        shoutcast:  require("./outputs/shoutcast")
        mp3:        require("./outputs/livemp3")
        sockets:    require("./outputs/sockets")
        
    #----------
        
    constructor: ->        
        @streams = {}
        
        @root_route = null
        
        # -- Don't crash on uncaughtException errors -- #
        
        process.on "uncaughtException", (error) =>
          @log.error "uncaught exception: " + error, stack:error.stack        

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
        
    # configureStreams can be called on a new core, or it can be called to 
    # reconfigure an existing core.  we need to support either one.
    configureStreams: (options) ->
        @log.debug "In configure with ", options:options

        # -- Sources -- #
        
        # are any of our current streams missing from the new options? if so, 
        # disconnect them
        for k,obj in @streams
            console.log "calling disconnect on ", k
            obj.disconnect() unless options.streams?[k]
            @streams.delete k
        
        # run through the streams we've been passed, initializing sources and 
        # creating rewind buffers
        for key,opts of options.streams
            console.log "stream for #{key}"
            if @streams[key]
                # existing stream...  pass it updated configuration
                @log.debug "Passing updated config to source: #{key}", opts:opts
                @streams[key].configure opts
            else
                @log.debug "Starting up source: #{key}", opts:opts
                @streams[key] = new @Stream @, key, @log.child(stream:key), opts
                
            # should this stream accept requests to /?
            if opts.root_route
                @root_route = key
                
    #----------
    
    # Build a hash of stream information, including sources and listener counts
    
    streamInfo: ->
        s.info() for k,s of @streams
                        
    #----------
    
    class @Standalone extends Core
        MODE: "StandAlone"
        constructor: (opts) ->
            @options = _u.defaults opts||{}, @DefaultOptions
            
            # -- Set up logging -- #
            
            @log = new Logger @options.log
            @log.debug("Instance initialized")
            
            # -- run Core's constructor -- #
            
            super()
            
            # -- set up our stream server -- #
            
            # init our server
            @server = new @Server @
            @server.listen @options.listen
                
            @log.debug "Standalone is listening on port #{@options.listen}"
        
            # start up the socket manager on the listener
            @sockets = new @Outputs.sockets io:@server.io, core:@
            
            # -- start the source listener -- #
            
            @sourcein = new @SourceIn core:@, port:opts.source_port
            
            # -- initialize streams -- #
            
            @configureStreams streams:@options.streams
    
    #----------
    
    # Master Server
    # 
    # Masters don't handle stream connections directly.  Instead they host 
    # configuration info and pass it on to slave servers.  They also consolidate 
    # slave logging data.
    
    class @Master extends Core
        
        MODE: "Master"
        constructor: (opts) ->
            @options = _u.defaults opts||{}, @DefaultOptions
            
            @slaves = []
            
            # -- set up logging -- #
            
            @log = new Logger @options.log
            @log.debug("Instance initialized")
            
            # -- allow Core's constructor to run -- #
            
            super()
            
            # -- load our streams configuration from redis -- #
            
            @redis = new @Redis @options.redis
            @redis.on "config", (streams) =>
                # stash the configuration
                @options.streams = streams
                
                # and then pass it on to any connected slaves
                for sock in @slaves
                    sock.emit "config", streams:streams
            
            # -- set up the socket connection for slaves -- #
            
            if !@options.master?.port || !@options.master?.password
                @log.error("Invalid options for master server.  Must provide port and password.")
                return false                
                
            # fire up a socket listener on our slave port
            @io = require("socket.io").listen @options.master?.port
            
            # disconnect from our port on SIGTERM
            process.on "SIGTERM", => @io.close()
            
            # add our authentication
            @io.configure =>
                @io.set "authorization", (data,cb) =>
                    # look for password                    
                    if @options.master.password
                        # make sure we got the same password in the query
                        if @options.master.password == data.query?.password
                            cb null, true
                        else
                            cb "Invalid slave password.", false
                    else
                        cb null, true
            
            # look for slave connections    
            @io.on "connection", (sock) =>
                @log.debug "slave connection is #{sock.id}"
                
                if @options.streams
                    # emit our configuration
                    sock.emit "config", streams:@options.streams
                    
                @slaves.push sock
                
                # attach event handler for log reporting
                socklogger = @log.child slave:sock.handshake.address.address
                sock.on "log", (obj = {}) => 
                    socklogger[obj.level||debug].apply socklogger, [obj.msg||"",obj.meta||{}]
                
            # attach disconnect handler
            @io.on "disconnect", (sock) =>
                @log.debug "slave disconnect from #{sock.id}"
                @slaves = _u(@slaves).without sock


    #----------
    
    # Slave Server
    #
    # Slaves are born only knowing how to connect to their master. The master 
    # gives them stream configuration, which the slave then uses to connect 
    # and provide up streams to clients.  Logging data is always passed back 
    # to the master, but can optionally also be stored on the slave host.
    
    class @Slave extends Core
        
        MODE: "Slave"
        constructor: (opts) ->
            @options = _u.defaults opts||{}, @DefaultOptions
            
            # -- Set up logging -- #
            
            @log = new Logger @options.log
            @log.debug("Instance initialized")
            
            # -- Make sure we have the proper slave config options -- #
            
            if !@options.slave?.master 
                @log.error "Invalid options for slave server. Must provide master."
                return false
                                
            # -- run Core's constructor -- #
            
            super()
            
            # -- set up our stream server -- #
            
            # init our server
            @server = new @Server @
            @server.listen @options.listen
            
            @log.debug "Slave is listening on port #{@options.listen}"
        
            # start up the socket manager on the listener
            @sockets = new @Outputs.sockets server:@server.server, core:@
                            
            # -- connect to the master server -- #
            
            @socket = require('socket.io-client').connect @options.slave.master
            
            @socket.on "connect", =>
                # connect up our logging proxy
                @log.proxyToMaster @socket
            
            @socket.on "config", (config) =>
                console.log "got config of ", config
                @configureStreams config
