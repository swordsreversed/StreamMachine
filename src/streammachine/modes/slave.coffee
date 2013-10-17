_u      = require "underscore"
nconf   = require "nconf"
cluster = require "cluster"
path    = require "path"

Logger  = require "../logger"
Slave   = require "../slave"

# Slave Server
#
# Slaves are born only knowing how to connect to their master. The master 
# gives them stream configuration, which the slave then uses to connect 
# and provide up streams to clients.  Logging data is always passed back 
# to the master, but can optionally also be stored on the slave host.

module.exports = class SlaveMode extends require("./base")
    
    MODE: "Slave"
    constructor: (@opts) ->
        @log = new Logger opts.log
        
        @log.debug("Slave Instance initialized")

        process.title = "StreamM:slave"
        super
        
        @workers = {}
        @lWorkers = {}
        @_handle = null
        @_haveHandle = false
        @_shuttingDown = false
        
        cluster.setupMaster
            exec: path.resolve(__dirname,"./slave_worker.js")
            args: ["--config",path.resolve(process.cwd(), nconf.get("config"))]
            
        cluster.on "online", (worker) =>
            console.log "SlaveWorker online: #{worker.id}"
            @workers[ worker.id ] = obj = w:worker, t:(new SlaveMode.HandoffTranslator worker)
            obj.t.send("listen",{},@_handle) if @_haveHandle
            
            if !@_handle
                obj.t.once "handle", (msg,handle) =>
                    @log.debug "Setting slave _handle based on handle from #{worker.id}"
                    @_handle = handle if !@_handle
                    
            obj.t.once "streams", =>
                @lWorkers[ worker.id ] = @workers[ worker.id ]
                @emit "worker_listening"
            
        cluster.on "disconnect", (worker) =>
            console.log "SlaveWorker disconnect: #{worker.id}"
            delete @lWorkers[worker.id]
            
        cluster.on "exit", (worker) =>
            console.log "SlaveWorker exit: #{worker.id}"
            delete @workers[ worker.id ]
            @_respawnWorkers() if !@_shuttingDown
            
        @_respawnWorkers()
        
        # -- are we looking for a handoff? -- #
        
        if nconf.get("handoff")
            @_acceptHandoff()
        else
            @_haveHandle = true
            w.t.send("listen") for id,w of @workers
            
        @once "server_handle", (handle) =>
            w.t.send("listen",{},handle) for id,w of @workers
    
    #----------
    
    _respawnWorkers: ->
        # if our worker count has dropped below our minimum, launch more workers
        wl = Object.keys(@workers).length
        _u.times ( nconf.get("cluster") - wl ), => cluster.fork()
    
    #----------
    
    _sendHandoff: (translator) ->
        @log.info "Starting slave handoff."
        
        # Coordinate handing off our server handle
        
        translator.send "server_socket", {}, @_handle
        
        translator.once "server_socket_up", =>
            @log.info "Server socket transferred. Sending listener connections."
            
            # now we ask each worker to send its listeners. We proxy them through
            # to the new process, which in turn hands them off to its workers
            
            currentWorker = null
            
            translator.on "stream_listener_ok", (msg) =>
                currentWorker.send "stream_listener_ok", msg
            
            _proxyWorker = (cb) =>
                # are we done yet?
                if Object.keys(cluster.workers).length == 0
                    cb?()
                    return false
                    
                # grab a worker id off the stack
                id = Object.keys(cluster.workers)[0]
                
                console.log "#{process.pid} STARTING #{id}"
                
                
                currentWorker = @workers[id].t
                
                # set up proxy function
                @workers[id].t.on "stream_listener", (obj,handle) =>
                    # send it on up river
                    translator.send "stream_listener", obj, handle
                    
                # listen for the all-clear
                @workers[id].t.once "sentAllListeners", =>
                    console.log "#{process.pid} DONE WITH #{id}"
                    # tell the worker we're done with its services
                    @workers[id].w.kill()
                    
                    # do it again...
                    _proxyWorker cb
                                
                # ask for listeners
                @workers[id].t.send "sendListeners"


            _proxyWorker =>
                @log.event "Sent slave data to new process. Exiting."

                # Exit
                process.exit()
    
    #----------
            
    _acceptHandoff: ->
        @log.info "Initializing handoff receptor."
        
        if !process.send?
            @log.error "Handoff called, but process has no send function. Aborting."
            return false
            
        console.log "Sending GO"
        process.send "HANDOFF_GO"
        
        # set up our translator
        translator = new SlaveMode.HandoffTranslator process
        
        # signal that we are configured (even though we may not be...)
        translator.send "streams"
        
        translator.once "server_socket", (msg,handle) =>
            @log.info "Got server socket."
            @_handle = handle
            @emit "server_socket", @_handle
            
        _go = =>
            translator.send "server_socket_up"
        
            # -- Watch for incoming listeners -- #
        
            translator.on "stream_listener", (msg,handle) =>
                # pick a worker randomly...
                worker_id = _u.sample(Object.keys(@workers))
                console.log "Picked #{worker_id} for listener destination."
            
                @workers[worker_id].t.once "stream_listener_ok", (msg) =>
                    translator.send "stream_listener_ok", msg
            
                @workers[worker_id].t.send "stream_listener", msg, handle
        
        if Object.keys(@lWorkers).length > 0
            _go()
        else
            @once "worker_listening", => _go()

    #----------
    
    class @SlaveWorker
        constructor: ->
            @log = new Logger nconf.get("log")
            @log.debug("SlaveWorker Instance initialized")
            
            @_t = new SlaveMode.HandoffTranslator process
            
            @slave = new Slave _u.extend nconf.get(), logger:@log
            
            @slave.once "streams", =>
                @_t.send "streams"
            
            @_t.once "listen", (msg,handle) =>
                if handle
                    @slave.server.listen handle
                    @log.debug "#{process.pid}: SlaveWorker listening via handle."
                    
                else
                    @slave.server.listen nconf.get("port"), =>
                        @log.debug "#{process.pid}: SlaveWorker listening via port #{nconf.get("port")}."
                    
                        # send our handle back upstream
                        @_t.send "handle", {}, @slave.server.hserver
            
            # Listen for the order to send our listeners to the cluster master, 
            # most likely as part of a handoff            
            @_t.once "sendListeners", (msg) =>
                @slave.sendHandoffData @_t, =>
                    @log.debug "All listeners sent."
                    @_t.send "sentAllListeners"
                    
            # We always register to be able to accept listeners
            @slave.loadHandoffData @_t
            
    #----------