RPC = require "ipc-rpc"
_ = require "underscore"

Logger  = require "../logger"
Slave   = require "./"

module.exports = class SlaveWorker
    constructor: ->
        @_config = null

        # -- Set up RPC -- #

        new RPC process, functions:
            send_handle: (msg,handle,cb) =>
                if @slave.server.hserver
                    cb null, null, @slave.server.hserver
                else
                    cb new Error "Worker doesn't have a handle to send."

            send_listeners: (msg,handle,cb) =>

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

        , (err,rpc) =>
            @_rpc = rpc

            console.log "Requesting config"
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

        # Listen for the order to send our listeners to the cluster master,
        # most likely as part of a handoff
        #@_t.once "sendListeners", (msg) =>
        #    @slave.sendHandoffData @_t, =>
        #        @log.debug "All listeners sent."
        #        @_t.send "sentAllListeners"

        # We always register to be able to accept listeners
        #@slave.loadHandoffData @_t