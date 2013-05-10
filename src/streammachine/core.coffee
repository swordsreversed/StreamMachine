_u      = require "underscore"
url     = require 'url'
http    = require "http"
express = require "express"
nconf   = require "nconf"

Logger  = require "./logger"
Master  = require "./master"
Slave   = require "./slave"

module.exports = class Core
    DefaultOptions:
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
    
    # Start a replacement process with our same command line arguments, plus 
    # the --handoff flag. Returns the childprocess.
    
    _spawnReplacement: (cb) ->
        cp = require "child_process"
        
        # arguments are in process.argv
        opts = require("optimist").argv
        
        new_args = _u(opts).omit "$0", "_", "handoff"
        
        new_args = ( "--#{k}=#{v}" for k,v of new_args )
        new_args.push("--handoff=true")
        
        console.log "argv is ", process.argv, process.execPath
        console.log "Spawning ", opts.$0, new_args
        newp = cp.fork process.argv[1], new_args

        newp.on "error", (err) =>
            @log.error "Spawned child gave error: #{err}", error:err

        newp.once "message", (m) =>
            # if all goes well, this first message will be a string that 
            # says 'HANDOFF_GO'
            
            if m == "HANDOFF_GO"
                # Good. now we set up a HandoffTranslator object
                translator = new Core.HandoffTranslator newp
                
                console.log "sR Registering for streams"
                translator.once "streams", =>
                    console.log "spawnReplacement got STREAMS"
                    cb? null, translator
            else
                @log.error "Invalid first message from handoff.", message:m
                        
    #----------
    
    class @StandaloneMode extends Core
        MODE: "StandAlone"
        constructor: (opts) ->
            @options = _u.defaults opts||{}, @DefaultOptions
                        
            @streams = {}
            
            # -- Set up logging -- #
            
            @log = (new Logger @options.log).child pid:process.pid
            
            
            @log.debug("Instance initialized")
            
            # -- Set up master and slave -- #
            
            @master = new Master _u.extend opts, logger:@log.child(mode:"master")
            @slave  = new Slave _u.extend opts, logger:@log.child(mode:"slave"), max_zombie_life:5000
            
            # -- Set up combined server -- #
            
            @server = express()
            @server.use "/admin", @master.admin.app
            @server.use @slave.server.app
            
            # -- Handoff? -- #
            
            if nconf.get("handoff")
                @_runHandoff()
            
            else
                @log.info "Attaching listeners."
                @master.sourcein.listen()
                @handle = @server.listen opts.listen
                        
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
            
            # -- restart handling -- #
            
            process.on "SIGHUP", =>
                if @_restarting
                    # we've already been asked to restart.  do nothing more
                    return false
                
                @_restarting = true
                
                # We've been asked to restart.  We do so by starting up a new 
                # process and scripting the handoff of master and slave data
                
                @log.event "Standalone process asked to restart."
                
                # Start the new process and wait for streams signal
                @_spawnReplacement (err,translator) =>
                    @log.event "Got streams signal from new process."
                    # Send master data (includes source port handoff)
                    @master.sendHandoffData translator, (err) =>
                        @log.event "Sent master data to new process."
                        
                        # Hand over our public listening port
                        @log.info "Hand off standalone socket."
                        translator.send "standalone_socket", {}, @handle
                        
                        translator.once "standalone_socket_up", =>
                            @log.info "Got standalone socket confirmation. Closing listener."
                            @handle.unref()
                                
                            # Hand over the source port
                            @log.info "Hand off source socket."
                            translator.send "source_socket", {}, @master.sourcein.server
                    
                            translator.once "source_socket_up", =>
                                @log.info "Got source socket confirmation. Closing listener."
                                @master.sourcein.server.unref()
                     
                                # Send slave data
                                @slave.sendHandoffData translator, (err) =>
                                    @log.event "Sent slave data to new process. Exiting."

                                    # Exit
                                    process.exit()
        
        #----------
                        
        _runHandoff: ->
            @log.info "Initializing handoff receptor."
            
            if !process.send?
                @log.error "Handoff called, but process has no send function. Aborting."
                return false
                
            console.log "Sending GO"
            process.send "HANDOFF_GO"
            
            # set up our translator
            translator = new Core.HandoffTranslator process
            
            # watch for streams
            @master.once "streams", =>
                console.log "Sending STREAMS"
                # signal that we're ready
                translator.send "streams"

                @master.loadHandoffData translator
                @slave.loadHandoffData translator
                
                # -- socket handovers -- #
                
                translator.once "standalone_socket", (msg,handle) =>
                    @log.info "Got standalone socket."
                    @handle = @server.listen handle
                    @log.info "Listening!"
                    translator.send "standalone_socket_up"
                    
                translator.once "source_socket", (msg,handle) =>
                    @log.info "Got source socket."
                    @master.sourcein.listen handle
                    @log.info "Listening for sources!"
                    translator.send "source_socket_up"
    
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
            
    #----------
    
    class @HandoffTranslator extends require("events").EventEmitter
        constructor: (@p) ->
            @p.on "message", (msg,handle) =>
                console.log "TRANSLATE GOT #{msg.key}", msg, handle?
                if msg?.key
                    msg.data = {} if !msg.data
                    @emit msg.key, msg.data, handle
            
        send: (key,data,handle=null) ->
            console.log "TRANSLATE #{key}", data, handle?
            @p.send { key:key, data:data }, handle
        
