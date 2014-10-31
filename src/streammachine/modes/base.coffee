_u = require "underscore"

#----------

module.exports = class Core extends require("events").EventEmitter
    DefaultOptions:
        # after a new deployment, allow a one hour grace period for
        # connected listeners
        max_zombie_life:    1000 * 60 * 60

    #----------

    constructor: ->
        @log.debug "Attaching listener for SIGUSR2 restarts."

        # Also support a handoff trigger via USR2
        process.on "SIGUSR2", =>
            if @_restarting
                return false

            @_restarting = true

            if @opts.handoff_type == "internal"
                # we spawn our own replacement process
                @_spawnReplacement (err,translator) =>
                    if err
                        @log.error "FATAL: Error spawning replacement process: #{err}", error:err
                        @_restarting = false
                        return false

                    @_sendHandoff translator

            else
                # replacement process is spawned externally

                # make sure there's an external process out there...
                if !@_rpc
                  @log.error "Master was asked for external handoff, but there is no RPC interface"
                  @_restarting = false
                  return false

                @log.info "Sending process for USR2. Starting handoff via proxy."

                @_rpc.request "HANDOFF_GO", null, null, timeout:10000, (err,reply) =>
                    if err
                        @log.error "Error handshaking handoff: #{err}"
                        @_restarting = false
                        return false

                    @log.info "Sender got handoff handshake. Starting send."
                    @_sendHandoff()

            _tTimeout = setTimeout =>
               @log.error "Timeout waiting for proxied handoff."
               # FIXME: not sure what else we should do
            , 10*1000

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
        newp = cp.fork process.argv[1], new_args, stdio:"inherit"

        newp.on "error", (err) =>
            @log.error "Spawned child gave error: #{err}", error:err

        @_handshakeHandoff newp, cb

    #----------

    _handshakeHandoff: (newp,cb) ->
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
                cb? "Invalid first message from handoff."

    #----------

    class @HandoffTranslator extends require("events").EventEmitter
        constructor: (@p) ->
            @p.on "message", (msg,handle) =>
                #console.log "#{process.pid} TR <- #{msg.key}", msg, handle?
                if msg?.key
                    msg.data = {} if !msg.data
                    @emit msg.key, msg.data, handle

        send: (key,data,handle=null) ->
            #console.log "#{process.pid} TR -> #{key}", data, handle?
            @p.send { key:key, data:data }, handle