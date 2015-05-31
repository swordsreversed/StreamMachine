_       = require "underscore"
nconf   = require "nconf"
path    = require "path"
RPC     = require "ipc-rpc"
net     = require "net"
CP      = require "child_process"

Logger  = require "../logger"
Slave   = require "../slave"

#----------

module.exports = class SlaveMode extends require("./base")

    MODE: "Slave"
    constructor: (@opts,cb) ->
        @log = (new Logger @opts.log).child({mode:'slave',pid:process.pid})
        @log.debug "Slave Instance initialized"

        process.title = "StreamM:slave"

        super

        @_handle        = null
        @_haveHandle    = false
        @_shuttingDown  = false
        @_inHandoff     = false

        @_lastAddress   = null
        @_initFull      = false

        # -- Set up Internal RPC -- #

        if process.send?
            @_rpc = new RPC process, timeout:5000, functions:
                slave_port: (msg,handle,cb) =>
                    if p = @slavePort()
                        cb null, p
                    else
                        cb new Error "No address returned yet."

                #---

                workers: (msg,handle,cb) =>

                #---

                stream_listener: (msg,handle,cb) =>
                    @_landListener null, msg, handle, cb

        # -- Set up Clustered Worker Pool -- #

        @pool = new SlaveMode.WorkerPool @, @opts.cluster, @opts
        @pool.on "full_strength", => @emit "full_strength"

        process.on "exit", =>
            @pool.destroy()

        # -- set up server -- #

        # We handle incoming connections here in the slave process, and then
        # distribute them to our ready workers.

        # If we're doing a handoff, we wait to receive a server handle from
        # the sending process. If not, we should go ahead and start a server
        # ourself.

        if nconf.get("handoff")
            @_acceptHandoff()
        else
            # we'll listen via our configured port
            @_openServer null, cb

    #----------

    slavePort: ->
        @_server?.address().port

    #----------

    _openServer: (handle,cb) ->
        @_server = net.createServer pauseOnConnect:true, allowHalfOpen:true
        @_server.listen handle || @opts.port, (err) =>
            if err
                @log.error "Failed to start slave server: #{err}"
                throw err

            @_server.on "connection", (conn) =>
                @_distributeConnection conn

            @log.info "Slave server is up and listening."

            cb? null, @

    #----------

    _distributeConnection: (conn) ->
        w = @pool.getWorker()

        if !w
            @pool.once "worker_loaded", =>
                @_distributeConnection conn

        w.rpc.request "connection", null, conn, (err) =>
            if err
                @log.error "Failed to land incoming connection: #{err}"
                conn.destroy()

    #----------

    shutdownWorker: (id,cb) ->
        @pool.shutdownWorker id, cb

    #----------

    status: (cb) ->
        # send back a status for each of our workers
        @pool.status cb

    #----------

    _listenerFromWorker: (id,msg,handle,cb) ->
        @log.debug "Landing listener from worker.", inHandoff:@_inHandoff
        if @_inHandoff
            # we're in a handoff. ship the listener out there
            @_rpc.request "stream_listener", msg, handle, (err) =>
                cb err
        else
            # we can hand the listener to any slave except the one
            # it came from
            @_landListener id, msg, handle, cb

    #----------

    # Distribute a listener to one of our ready slave workers. This could be
    # an external request via handoff, or it could be an internal request from
    # a worker instance that is shutting down.

    _landListener: (sender,obj,handle,cb) ->
        w = @pool.getWorker sender

        if w
            @log.debug "Asking to land listener on worker #{w.id}"
            w.rpc.request "land_listener", obj, handle, (err) =>
                cb err
        else
            @log.debug "No worker ready to land listener!"
            cb "No workers ready to receive listeners."

    #----------

    _sendHandoff: () ->
        @log.info "Starting slave handoff."

        # don't try to spawn new workers
        @_shuttingDown  = true
        @_inHandoff     = true

        # Coordinate handing off our server handle

        @_rpc.request "server_socket", {}, @_server?._handle, (err) =>
            if err
                @log.error "Error sending socket across handoff: #{err}"
                # FIXME: Proceed? Cancel?

            @log.info "Server socket transferred. Sending listener connections."

            # now we ask each worker to send its listeners. We proxy them through
            # to the new process, which in turn hands them off to its workers

            _proxyWorker = (cb) =>
                # are we done yet?
                if Object.keys(cluster.workers).length == 0
                    cb?()
                    return false

                # grab a worker id off the stack
                id = Object.keys(cluster.workers)[0]

                console.log "#{process.pid} STARTING #{id}"

                @workers[id].rpc.request "send_listeners", (err,msg) =>
                    if err
                        @log.error "Worker hit error sending listeners during handoff: #{err}", error:err, worker:id

                    # tell the worker we're done with its services
                    @workers[id].w.kill()

                    # do it again...
                    _proxyWorker cb

            _proxyWorker =>
                @log.event "Sent slave data to new process. Exiting."

                # Exit
                process.exit()

    #----------

    _acceptHandoff: ->
        @log.info "Initializing handoff receptor."

        if !@_rpc
            @log.error "Handoff called, but no RPC interface set up. Aborting."
            return false

        @_rpc.once "HANDOFF_GO", (msg,handle,cb) =>
            @_rpc.once "server_socket", (msg,handle,cb) =>
                @_handle        = handle
                @_haveHandle    = true
                @emit "server_socket"

                _go = =>
                    # let our sender know we're ready... we're already listening for
                    # the stream_listener requests on our rpc, so our job in here is
                    # done. The rest is on the sender.
                    cb null

                # wait until we're at full strength to start transferring listeners
                if @_initFull
                    _go()
                else
                    @once "full_strength", => _go()


            cb null, "GO"

        if !process.send?
            @log.error "Handoff called, but process has no send function. Aborting."
            return false

        console.log "Sending GO"
        process.send "HANDOFF_GO"

    #----------

    class @WorkerPool extends require("events").EventEmitter
        constructor: (@s,@size,@config) ->
            @workers = {}

            @log = @s.log.child component:"worker_pool"

            @_nextId = 1

            @_spawn()

        #----------

        _spawn: ->
            if @count() >= @size
                @log.debug "Pool is at full strength"
                @emit "full_strength"
                return false

            p = CP.fork path.resolve(__dirname,"./slave_worker.js")

            id = @_nextId
            @_nextId += 1

            @log.debug "Spawning new worker.", count:@count(), target:@size

            w = new SlaveMode.Worker
                id:         id
                w:          p
                rpc:        null
                pid:        p.pid
                _loaded:    false

            w.rpc = new RPC p, functions:

                # triggered by the worker once it has its streams configured
                # (though they may not yet have data to give out)
                worker_configured: (msg,handle,cb) =>
                    @log.debug "Worker #{w.id} is configured."
                    cb null

                #---

                # sent by the worker once its stream rewinds are loaded.
                # tells us that it's safe to trigger a new worker launch
                rewinds_loaded: (msg,handle,cb) =>
                    @log.debug "Worker #{w.id} is loaded."
                    w._loaded = true
                    @emit "worker_loaded"

                    # ACK
                    cb null

                    # now that we're done, see if any more workers need to start
                    @_spawn()

                #---

                # a worker is allowed to shed listeners at any point by
                # sending them here. This could be part of a handoff (where
                # we've asked for the listeners), or part of the worker
                # crashing / shutting down
                send_listener: (msg,handle,cb) =>
                    @s._listenerFromWorker w.id, msg, handle, cb

                #---

                # triggered by the worker to request configuration
                config: (msg,handle,cb) =>
                    cb null, @config

            , (err) =>
                if err
                    @log.error "Error setting up RPC for new worker: #{err}"
                    worker.kill()
                    return false

                @log.debug "Worker #{w.id} is set up.", id:w.id, pid:w.pid

                @workers[ w.id ] = w

            # -- Handle disconnects and exits -- #

            p.once "exit", =>
                @log.info "SlaveWorker exit: #{w.id}"
                delete @workers[ w.id ]

                w.emit "exit"
                w.destroy()

                @_spawn() if !@s._shuttingDown

        #----------

        count: ->
            Object.keys(@workers).length

        #----------

        loaded_count: ->
            _(@workers).select((w) -> w._loaded).length

        #----------

        destroy: ->
            # send kill signals to all workers
            @log.info "Slave WorkerPool is exiting."
            w.w.kill() for id,w of @workers

        #----------

        shutdownWorker: (id,cb) ->
            if !@workers[id]
                cb? "Cannot call shutdown: Worker id unknown"
                return false

            @log.info "Sending shutdown to worker #{id}"
            @workers[id].rpc.request "shutdown", {}, (err) =>
                if err
                    @log.error "Shutdown errored: #{err}"
                    return false

                cb = _.once cb

                # set a shutdown timer
                timer = setTimeout =>
                    cb "Failed to get worker exit before timeout."
                , 1000

                # now watch for the worker's exit event
                @workers[id].once "exit", =>
                    @log.info "Shutdown succeeded for worker #{id}."
                    clearTimeout timer if timer
                    cb null

        #----------

        getWorker: (exclude_id) ->
            # we want loaded workers, excluding the passed-in id if provided
            workers = if exclude_id
                _(@workers).select (w) -> w._loaded && w.id != exclude_id
            else
                _(@workers).select (w) -> w._loaded

            if workers.length == 0
                return null
            else
                # FIXME: Right now we just return a random worker, but this selection
                # should use some sense of worker busyness
                return _.sample(workers)

        #----------

        status: (cb) ->
            status = {}

            af = _.after Object.keys(@workers).length, =>
                cb null, status

            for id,w of @workers
                do (id,w) =>
                    w.rpc.request "status", (err,s) =>
                        @log.error "Worker status error: #{err}" if err
                        status[ id ] = id:id, listening:w._listening, loaded:w._loaded, streams:s, pid:w.pid
                        af()

    #----------

    class @Worker extends require("events").EventEmitter
        constructor: (attributes) ->
            @[k] = v for k,v of attributes

        destroy: ->
            @removeAllListeners()
