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
    constructor: (@opts) ->
        @log = new Logger @opts.log
        @log.debug "Slave Instance initialized"

        process.title = "StreamM:slave"

        super

        @workers        = {}
        @lWorkers       = {}
        @_handle        = null
        @_haveHandle    = false
        @_shuttingDown  = false

        cluster.setupMaster
            exec: path.resolve(__dirname,"./slave_worker.js")

        cluster.on "online", (worker) =>
            console.log "SlaveWorker online: #{worker.id}"

            w = w:worker, rpc:null, _listening:false

            w.rpc = new RPC worker, functions:
                worker_configured: (msg,handle,cb) =>
                    if @_haveHandle && !w._listening
                        w.rpc.request "listen", {fd:@_handle?.fd}, (err) =>
                            @log.error "Worker listen error: #{err}" if err
                            w._listening = true
                            @lWorkers[ worker.id ] = w

                            @emit "worker_listening"

                    cb null

                config: (msg,handle,cb) =>
                    cb null, @opts

            , (err) =>
                if err
                    @log.error "Error setting up RPC for new worker: #{err}"
                    worker.kill()
                    return false

                @workers[ worker.id ] = w

            #console.log "Asking worker to listen to ", @_handle?.fd
            #obj.t.send("listen",fd:@_handle?.fd) if @_haveHandle

            #obj.t.once "streams", =>
            #    @lWorkers[ worker.id ] = @workers[ worker.id ]
            #    @emit "worker_listening"

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
            # we'll listen via our configured port
            @_haveHandle = true
            for id,w of @workers
                w.rpc.request "listen", null, (err) =>
                    @log.error "Worker listen error: #{err}" if err

        #@once "server_handle", =>
        #    w.t.send("listen",fd:@_handle.fd) for id,w of @workers

    #----------

    _respawnWorkers: ->
        # if our worker count has dropped below our minimum, launch more workers
        wl = Object.keys(@workers).length
        _.times ( nconf.get("cluster") - wl ), => cluster.fork()

    #----------

    _sendHandoff: (translator) ->
        @log.info "Starting slave handoff."

        # don't try to spawn new workers
        @_shuttingDown = true

        # Coordinate handing off our server handle

        _send = (handle) =>
            translator.send "server_socket", {}, handle

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

        # we need to pass over a copy of the server handle.  We ask the
        # workers for it and go with the first one that comes back

        _handleSent = false

        if @_handle
            _send @_handle
        else
            _askHandle = (id,w) =>
                w.t.once "handle", (msg,handle) =>
                    if !_handleSent
                        _handleSent = true
                        _send handle._handle

                @log.debug "Sending req_handle to #{id}"
                w.t.send "req_handle"

            _askHandle(id,w) for id,w of @lWorkers

    #----------

    _acceptHandoff: ->
        @log.info "Initializing handoff receptor."

        if !@_rpc
            @log.error "Handoff called, but no RPC interface set up. Aborting."
            return false

        @_rpc.once "HANDOFF_GO", (msg,handle,cb) =>
            cb null, "GO"



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
            @_handle = handle

            # don't accept connections here...
            #handle._handle.onconnection = (client) =>
            #    console.log "CONNECTION IN SLAVE-MASTER>>> CLOSING"
            #    client.close(); false

            console.log "GOT SERVER SOCKET: ", handle
            @_haveHandle = true
            @emit "server_socket"

            _go = =>
                translator.send "server_socket_up"

                # -- Watch for incoming listeners -- #

                translator.on "stream_listener", (msg,handle) =>
                    # pick a worker randomly...
                    worker_id = _.sample(Object.keys(@lWorkers))
                    console.log "Picked #{worker_id} for listener destination."

                    @workers[worker_id].t.once "stream_listener_ok", (msg) =>
                        translator.send "stream_listener_ok", msg

                    @workers[worker_id].t.send "stream_listener", msg, handle

            if Object.keys(@lWorkers).length > 0
                _go()
            else
                @once "worker_listening", => _go()

    #----------
