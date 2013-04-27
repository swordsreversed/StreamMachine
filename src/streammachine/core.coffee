_u = require("underscore")
url = require('url')
http = require "http"
express = require "express"
Logger = require "./logger"

Master  = require "./master"
Slave   = require "./slave"

module.exports = class Core
    DefaultOptions:
        streams:            {}
        # after a new deployment, allow a one hour grace period for 
        # connected listeners
        max_zombie_life:    1000 * 60 * 60
        
    Redis:  require "./redis_config"
    Rewind: require "./rewind_buffer"
        
    Sources:
        proxy:      require("./sources/proxy_room")
        icecast:    require("./sources/icecast")
        

    #----------
    
    # Build a hash of stream information, including sources and listener counts
    
    streamInfo: ->
        s.info() for k,s of @streams
                        
    #----------
    
    class @StandaloneMode extends Core
        MODE: "StandAlone"
        constructor: (opts) ->
            @options = _u.defaults opts||{}, @DefaultOptions
            
            @streams = {}
            
            # -- Set up logging -- #
            
            @log = new Logger @options.log
            @log.debug("Instance initialized")
                        
            # set up a master
            @master = new Master _u.extend opts, logger:@log.child(mode:"master")
            @slave  = new Slave _u.extend opts, logger:@log.child(mode:"slave")
            
            # -- Set up combined server -- #
            
            @server = express()
            @server.use "/admin", @master.admin.app
            @server.use @slave.server.app
            @server.listen opts.listen
                        
            # proxy data events from master -> slave
            @master.on "streams", (streams) =>
                @slave.configureStreams @master.config().streams                
                @slave._onConnect()
                
                #console.log "in standalone streams", streams
                process.nextTick =>
                    for k,v of streams 
                        console.log "looking to attach #{k}", @streams[k]?, @slave.streams[k]?
                        if @streams[k]
                            # got it already
                            
                        else
                            if @slave.streams[k]?
                                console.log "mapping master -> slave on #{k}"
                                @slave.streams[k].useSource v
                                @streams[k] = true
                            else
                                console.log "Unable to map master -> slave for #{k}"
                    
            @slave.on "listeners", (obj) =>
                @master._recordListeners "standalone", obj
            
            @log.debug "Standalone is listening on port #{@options.listen}"
                    
    
    #----------
    
    # Master Server
    # 
    # Masters don't take client connections directly. They take incoming 
    # source streams and proxy them to the slaves, providing an admin 
    # interface and a point to consolidate logs and listener counts.
    
    class @MasterMode extends Core
        
        MODE: "Master"
        constructor: (opts) ->
            @log = new Logger opts.log
            @log.debug("Master Instance initialized")
            
            # create a master
            @master = new Master _u.extend opts, logger:@log
            
            # Listen on the master port
            @server = @master.admin.listen opts.master.port
            
            # Also attach sockets for slaves
            @master.listenForSlaves(@server)

    #----------
    
    # Slave Server
    #
    # Slaves are born only knowing how to connect to their master. The master 
    # gives them stream configuration, which the slave then uses to connect 
    # and provide up streams to clients.  Logging data is always passed back 
    # to the master, but can optionally also be stored on the slave host.
    
    class @SlaveMode extends Core
        
        MODE: "Slave"
        constructor: (opts) ->
            @log = new Logger opts.log
            @log.debug("Slave Instance initialized")
            
            # create a slave
            @slave = new Slave _u.extend opts, logger:@log
            
            @slave.server.app.listen opts.port
