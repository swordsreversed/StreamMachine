_       = require "underscore"
express = require "express"
nconf   = require "nconf"

Logger  = require "../logger"
Master  = require "../master"
Slave   = require "../slave"

module.exports = class StandaloneMode extends require("./base")
    MODE: "StandAlone"
    constructor: (@opts,cb) ->
        # -- Set up logging -- #

        @log = (new Logger @opts.log).child pid:process.pid
        @log.debug("StreamMachine standalone initialized.")

        process.title = "StreamMachine"

        super

        @streams = {}

        # -- Set up master and slave -- #

        @master = new Master _.extend {}, @opts, logger:@log.child(mode:"master")
        @slave  = new Slave _.extend {}, @opts, logger:@log.child(mode:"slave")

        # -- Set up combined server -- #

        @server = express()
        @server.use "/api", @master.api.app
        @server.use @slave.server.app

        # -- Handoff? -- #

        if nconf.get("handoff")
            @_acceptHandoff()

        else
            @log.info "Attaching listeners."
            @master.sourcein.listen()
            @handle = @server.listen @opts.port

        # proxy data events from master -> slave
        @master.on "streams", (streams) =>
            @slave.once "streams", =>
                for k,v of streams
                    @log.debug "looking to attach stream #{k}", streams:@streams[k]?, slave_streams:@slave.streams[k]?
                    if @streams[k]
                        # got it already

                    else
                        if @slave.streams[k]?
                            @log.debug "mapping master -> slave on #{k}"
                            @slave.streams[k].useSource v
                            @streams[k] = true
                        else
                            @log.error "Unable to map master -> slave for #{k}"

            @slave.configureStreams @master.config().streams

        @log.debug "Standalone is listening on port #{@opts.port}"

        cb null, @

    #----------

    _sendHandoff: (translator) ->
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

    _acceptHandoff: ->
        @log.info "Initializing handoff receptor."

        if !process.send?
            @log.error "Handoff called, but process has no send function. Aborting."
            return false

        console.log "Sending GO"
        process.send "HANDOFF_GO"

        # set up our translator
        translator = new StandaloneMode.HandoffTranslator process

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
