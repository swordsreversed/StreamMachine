_u = require "underscore"

Stream = require "./stream"
Server = require "./server"

Socket = require "socket.io-client"

URL = require "url"
HTTP = require "http"

module.exports = class Slave extends require("events").EventEmitter
    DefaultOptions:
        max_zombie_life:    1000 * 60 * 60

    Outputs:
        pumper:         require "../outputs/pumper"
        shoutcast:      require "../outputs/shoutcast"
        raw:            require "../outputs/raw_audio"
        sockets:        require "../outputs/sockets"
        live_streaming: require "../outputs/live_streaming"

    constructor: (opts) ->
        @options = _u.defaults opts||{}, @DefaultOptions

        @streams = {}
        @root_route = null

        @connected = false

        @_retrying = null
        @_retryConnection = =>
            @log.debug "Failed to connect to master. Trying again in 5 seconds."
            @_retrying = setTimeout =>
                @log.debug "Retrying connection to master."
                @_connectMaster()
            , 5000

        # -- Set up logging -- #

        @log = @options.logger

        # -- Make sure we have the proper slave config options -- #

        if @options.slave?.master
            # -- connect to the master server -- #

            @log.debug "Connecting to master at ", master:@options.slave.master

            @_connectMaster()

        # -- set up our stream server -- #

        # init our server
        @server = new Server core:@, logger:@log.child(subcomponent:"server")

        # start up the socket manager on the listener
        #@sockets = new @Outputs.sockets server:@server.server, core:@

        # -- Listener Counts -- #

        # once every 10 seconds, count all listeners and send them on to the master

        @_listeners_interval = setInterval =>
            return if !@connected?

            counts = {}
            total = 0

            for k,s of @streams
                l = s.listeners()
                counts[k] = l
                total += l

            @log.debug "sending listeners: #{total}", counts

            @emit "listeners", counts:counts, total:total
            @master?.emit "listeners", counts:counts, total:total

        , 10 * 1000

        # -- Buffer Stats -- #

        @_buffer_interval = setInterval =>
            return if !@connected?

            counts = []
            for k,s of @streams
                counts.push [s.key,s._rbuffer?.length].join(":")

            @log.debug "Rewind buffers: " + counts.join(" -- ")

        , 5 * 1000

    #----------

    _connectMaster: ->
        @log.info "Slave trying connection to master."
        @master = Socket.connect @options.slave.master, "connect timeout":5000

        @master.on "connect", => @_onConnect()
        @master.on "reconnect", => @_onConnect()

        @master.on "connect_failed", @_retryConnection
        @master.on "error", (err) =>
            if err.code =~ /ECONNREFUSED/
                @_retryConnection()
            else
                @log.info "Slave got connection error of #{err}", error:err
                console.log "got connection error of ", err

        @master.on "config", (config) =>
            @configureStreams config.streams

        @master.on "disconnect", =>
            @_onDisconnect()

    #----------

    _onConnect: ->
        @log.debug "Slave in _onConnect."
        return false if @connected

        if @_retrying
            clearTimeout @_retrying
            @_retrying = null

        @log.debug "Slave is connected."

        @connected = true

        if @master
            # connect up our logging proxy
            @log.debug "Connected to master."
            @log.proxyToMaster @master

        true

    _onDisconnect: ->
        @connected = false
        @log.debug "Disconnected from master."
        #@server?.stopListening()

        @log.proxyToMaster()

        true

    #----------

    configureStreams: (options) ->
        @log.debug "In slave configureStreams with ", options:options

        # are any of our current streams missing from the new options? if so,
        # disconnect them
        for k,obj in @streams
            console.log "calling disconnect on ", k
            obj.disconnect() unless options?[k]
            @streams.delete k

        # run through the streams we've been passed, initializing sources and
        # creating rewind buffers
        for key,opts of options
            console.log "Slave stream for #{key}"
            if @streams[key]
                # existing stream...  pass it updated configuration
                @log.debug "Passing updated config to source: #{key}", opts:opts
                @streams[key].configure opts
            else
                @log.debug "Starting up source: #{key}", opts:opts

                slog = @log.child stream:key
                @streams[key] = new Stream @, key, slog, opts

            # should this stream accept requests to /?
            if opts.root_route
                @root_route = key

        # emit a streams event for any components under us that might
        # need to know
        @emit "streams", @streams

    #----------

    socketSource: (stream) ->
        new Slave.SocketSource @, stream

    #----------

    sendHandoffData: (translator,cb) ->
        # need to transfer listeners and their offsets to the new process

        # Internally, node has to send sockets one at a time and wait for an
        # ack. Because of this (and because of an issue where handles aren't
        # checked to see if they're still valid before Node tries to send
        # them), we need to send listeners one at a time, waiting for an ack
        # each time.

        @log.info "Sending slave handoff data."

        # we need to track in-flight listeners to make sure they get there
        @_boarding  = []
        @_inflight  = null

        # -- prep our connections -- #

        # we've already handed off our server socket, so we don't need to
        # worry about new listeners coming in.  Existing listeners could
        # drop between now and when we actually send, though.

        for k,s of @streams
            @log.info "Handoff preparing #{ Object.keys(s._lmeta).length } listeners for #{ s.key }."
            @_boarding.push [s,obj] for id,obj of s._lmeta

        # -- short-circuit if there are no listeners -- #

        if @_boarding.length == 0
            cb?()
            return true

        # -- now send them one-by-one -- #

        sFunc = =>
            if sl = @_boarding.shift()
                [stream,l] = sl

                # wrap the listener send in an error domain to try as
                # hard as we can to get it all there
                d = require("domain").create()
                d.on "error", (err) =>
                    console.error "Handoff error: #{err}"
                    @log.error "Send handoff listener for #{l.id} hit error: #{err}"
                    d.exit()
                    sFunc()

                d.run =>
                    l.obj.prepForHandoff =>
                        lobj =
                            timer:  null,
                            ack:    false,
                            socket: l.obj.socket,
                            opts:
                                key:        [stream.key,l.id].join("::"),
                                stream:     stream.key
                                id:         l.id
                                startTime:  l.startTime
                                minuteTime: l.minuteTime
                                client:     l.obj.client

                        # there's a chance that the connection could end
                        # after we recorded the id but before we get here.
                        # don't send in that case...
                        if lobj.socket && !lobj.socket.destroyed
                            translator.send "stream_listener", lobj.opts, lobj.socket

                            # mark them as in-flight
                            @_inflight = lobj.opts.key

                        else
                            @log.info "Lost listener #{lobj.opts.id} during taxi. Moving on."
                            sFunc()

            else
                # all done!
                @log.info "Last listener is in flight."

                if !@_inflight
                    @log.info "All listeners are arrived or lost."
                    cb?()

        # -- register a listener for acks -- #

        translator.on "stream_listener_ok", (msg) =>
            console.log "Got ACK on ", msg
            if @_inflight == msg.key
                @log.info "Successful ack for listener #{msg.key}. Boarding length is #{@_boarding.length}"

            @_inflight = null

            if @_boarding.length > 0
                sFunc()

            else
                @log.info "All listeners are arrived."
                cb?()

        # start the show...

        sFunc()

    #----------

    loadHandoffData: (translator,cb) ->

        @_seen = {}

        # -- look for transferred listeners -- #

        translator.on "stream_listener", (obj,socket) =>
            if !@_seen[ obj.key ]
                # check and make sure they haven't disconnected mid-flight
                if socket && !socket.destroyed
                    # create an output and attach it to the proper stream
                    output = new @Outputs[ obj.client.output ] @streams[ obj.stream ],
                        socket:     socket
                        client:     obj.client
                        startTime:  new Date(obj.startTime)
                        minuteTime: new Date(obj.minuteTime)

                @_seen[obj.key] = 1

            # -- ACK that we received the listener -- #

            translator.send "stream_listener_ok", key:obj.key

    #----------

    # emulate a source connection, receiving data via sockets from our master server

    class @SocketSource extends require("events").EventEmitter
        constructor: (@slave,@stream) ->
            @log = @stream.log.child subcomponent:"socket_source"

            @log.debug "created SocketSource for #{@stream.key}"

            @slave.master.on "streamdata:#{@stream.key}",    (chunk) =>
                # our data gets converted into an octet array to go over the
                # socket. convert it back before insertion
                chunk.data = new Buffer(chunk.data)

                # convert timestamp back to a date object
                chunk.ts = new Date(chunk.ts)

                @emit "data", chunk

            @_streamKey = null

            @slave.master.emit "stream_stats", @stream.key, (err,obj) =>
                @_streamKey = obj.streamKey
                @emit "vitals", obj

            #@slave.master.on "disconnect", =>
            #    @emit "disconnect"

        #----------

        getStreamKey: (cb) ->
            if @_streamKey
                cb? @_streamKey
            else
                @once "vitals", => cb? @_streamKey

        getRewind: (cb) ->
            # connect to the master's StreamTransport and ask for any rewind
            # buffer that is available

            gRT = setTimeout =>
                @log.debug "Failed to get rewind buffer response."
                cb? "Failed to get a rewind buffer response."
            , 15000

            # connect to: @master.options.host:@master.options.port

            # GET request for rewind buffer
            @log.debug "Making Rewind Buffer request for #{@stream.key}", sock_id:@slave.master.socket.sessionid
            req = HTTP.request
                hostname:   @slave.master.socket.options.host
                port:       @slave.master.socket.options.port
                path:       "/s/#{@stream.key}/rewind"
                headers:
                    'stream-slave-id':    @slave.master.socket.sessionid
            , (res) =>
                clearTimeout gRT

                @log.debug "Got Rewind response with status code of #{ res.statusCode }"
                if res.statusCode == 200
                    # emit a 'rewind' event with a callback to get the response
                    cb? null, res, req

                else
                    cb? "Rewind request got a non-500 response."

            req.on "error", (err) =>
                clearTimeout gRT

                @log.debug "Rewind request got error: #{err}", error:err
                cb? err

            req.end()

        #----------

        disconnect: ->
            console.log "SocketSource disconnect for #{@stream.key} called"
