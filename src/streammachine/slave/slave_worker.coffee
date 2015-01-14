RPC = require "ipc-rpc"
_ = require "underscore"

Logger  = require "../logger"
Slave   = require "./"

module.exports = class SlaveWorker
    constructor: ->
        @_config = null

        # -- Set up RPC -- #

        new RPC process, functions:
            status: (msg,handle,cb) =>
                @slave._streamStatus cb

            #---

            send_handle: (msg,handle,cb) =>
                if @slave.server.hserver
                    cb null, null, @slave.server.hserver
                else
                    cb new Error "Worker doesn't have a handle to send."

            #---

            # Accept a listener that we should now start serving
            land_listener: (msg,handle,cb) =>
                @slave.landListener msg, handle, cb

            #---

            # Request to send all our listeners to the main slave process,
            # probably so that it can whack us
            send_listeners: (msg,handle,cb) =>
                @slave.ejectListeners (obj,h,lcb) =>
                    @_rpc.request "send_listener", obj, h, (err) =>
                        lcb()

                , (err) =>
                    cb err

            #---

            listen: (msg,handle,cb) =>
                listen_via = if msg.fd? then { fd:msg.fd } else @_config.port

                @log.debug "Listen request via #{ listen_via }"

                cb = _.once cb
                @slave.server.once "error", (err) =>
                    @log.error "SlaveWorker listen failed: #{err}"
                    cb err

                @slave.server.listen listen_via, =>
                    @log.debug "SlaveWorker listening via #{ listen_via }."
                    cb null, @slave.server.hserver.address()

            #---

        , (err,rpc) =>
            @_rpc = rpc

            @_rpc.request "config", (err,obj) =>
                if err
                    console.error "Error loading config: #{err}"
                    process.exit(1)

                @_config = obj

                @log = (new Logger @_config.log).child mode:"slave_worker", pid:process.pid
                @log.debug("SlaveWorker initialized")

                @slave = new Slave _.extend @_config, logger:@log

                @slave.once_configured =>
                    @_rpc.request "worker_configured", (err) =>
                        if err
                            @log.error "Error sending worker_configured: #{err}"
                        else
                            @log.debug "Controller ACKed that we're configured."