_       = require "underscore"
nconf   = require "nconf"
cluster = require "cluster"
path    = require "path"
RPC     = require "ipc-rpc"

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
    constructor: (@opts,cb) ->
        @log = (new Logger @opts.log).child({component:'slave',pid:process.pid})
        @log.debug "Slave Instance initialized"

        process.title = "StreamM:slave"

        super

        @workers        = {}
        @lWorkers       = {}
        @_handle        = null
        @_haveHandle    = false
        @_shuttingDown  = false
        @_inHandoff     = false

        @_lastAddress   = null

        # -- Set up Internal RPC -- #

        if process.send?
            @_rpc = new RPC process, timeout:5000, functions:
                slave_port: (msg,handle,cb) =>
                    if @_lastAddress
                        cb null, @_lastAddress.port
                    else
                        cb new Error "No address returned yet."

                #---

                workers: (msg,handle,cb) =>

                #---

                stream_listener: (msg,handle,cb) =>
                    @_landListener msg, handle, cb

        # -- Set up Clustered Workers -- #

        cluster.setupMaster
            exec: path.resolve(__dirname,"./slave_worker.js")

        cluster.on "online", (worker) =>
            @log.info "SlaveWorker online: #{worker.id}"

            w = id:worker.id, w:worker, rpc:null, _listening:false, pid:worker.process.pid

            w.rpc = new RPC worker, functions:
                worker_configured: (msg,handle,cb) =>
                    if @_haveHandle && !w._listening
                        w.rpc.request "listen", {fd:@_handle?.fd}, (err,address) =>
                            if err
                                @log.error "Worker listen error: #{err}" if err
                                return false

                            w._listening = true
                            @lWorkers[ w.id ] = w
                            @_lastAddress = address

                            @emit "worker_listening"

                            if Object.keys(@lWorkers).length >= @opts.cluster
                                @emit "full_strength"

                    cb null

                #---

                # a worker is allowed to shed listeners at any point by
                # sending them here. This could be part of a handoff (where
                # we've asked for the listeners), or part of the worker
                # crashing / shutting down
                send_listener: (msg,handle,cb) =>
                    if @_inHandoff
                        # we're in a handoff. ship the listener out there
                        @_rpc.request "stream_listener", msg, handle, (err) =>
                            cb err
                    else
                        # FIXME: Implement non-handoff listener redistribution

                #---

                config: (msg,handle,cb) =>
                    cb null, @opts

            , (err) =>
                if err
                    @log.error "Error setting up RPC for new worker: #{err}"
                    worker.kill()
                    return false

                @workers[ worker.id ] = w

        cluster.on "disconnect", (worker) =>
            @log.info "SlaveWorker disconnect: #{worker.id}"
            delete @lWorkers[worker.id]

        cluster.on "exit", (worker) =>
            @log.info "SlaveWorker exit: #{worker.id}"
            delete @workers[ worker.id ]
            @_respawnWorkers() if !@_shuttingDown

        @_respawnWorkers()

        # -- are we looking for a handoff? -- #

        if nconf.get("handoff")
            @_acceptHandoff()
        else
            # we'll listen via our configured port
            @_haveHandle = true
            cb? null, @


    #----------

    _respawnWorkers: ->
        # if our worker count has dropped below our minimum, launch more workers
        wl = Object.keys(@workers).length
        _.times ( @opts.cluster - wl ), => cluster.fork()

    #----------

    status: (cb) ->
        # send back a status for each of our workers
        status = {}
        af = _.after Object.keys(@workers).length, =>
            cb null, status

        for id,w of @workers
            do (id,w) =>
                w.rpc.request "status", (err,s) =>
                    status[ id ] = listening:w._listening, streams:s, pid:w.pid
                    af()

    #----------

    _landListener: (obj,handle,cb) ->
        worker_ids = Object.keys(@workers)

        if worker_ids.length == 0
            cb "No workers ready to receive listeners."
        else
            id = _.sample(worker_ids)
            @workers[id].rpc.request "land_listener", obj, handle, (err) =>
                cb err

    #----------

    _sendHandoff: () ->
        @log.info "Starting slave handoff."

        # don't try to spawn new workers
        @_shuttingDown  = true
        @_inHandoff     = true

        # Coordinate handing off our server handle

        _send = (handle) =>
            @_rpc.request "server_socket", {}, handle, (err) =>
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

        # we need to pass over a copy of the server handle.  We ask the
        # workers for it and go with the first one that comes back

        _handleSent = false

        if @_handle
            _send @_handle
        else
            _askHandle = (id,w) =>
                @log.debug "Asking worker #{id} for server handle"
                w.rpc.request "send_handle", (err,msg,handle) =>
                    # error is going to be "I don't have a handle to send", so
                    # we'll just check whether we got a handle back
                    if handle? && !_handleSent
                        _handleSent = true
                        _send handle._handle
                        @log.debug "Worker #{id} replied with server handle"

            _askHandle(id,w) for id,w of @lWorkers

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

                if Object.keys(@lWorkers).length > 0
                    _go()
                else
                    @once "worker_listening", => _go()


            cb null, "GO"

        if !process.send?
            @log.error "Handoff called, but process has no send function. Aborting."
            return false

        console.log "Sending GO"
        process.send "HANDOFF_GO"

    #----------
