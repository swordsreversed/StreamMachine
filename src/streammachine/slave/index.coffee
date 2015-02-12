_u = require "underscore"

Stream  = require "./stream"
Server  = require "./server"
Alerts  = require "../alerts"
IO      = require "./slave_io"

URL     = require "url"
HTTP    = require "http"
tz      = require 'timezone'

module.exports = class Slave extends require("events").EventEmitter
    DefaultOptions:
        max_zombie_life:    1000 * 60 * 60

    Outputs:
        pumper:         require "../outputs/pumper"
        shoutcast:      require "../outputs/shoutcast"
        raw:            require "../outputs/raw_audio"
        live_streaming: require "../outputs/live_streaming"

    constructor: (opts) ->
        @options = _u.defaults opts||{}, @DefaultOptions

        @_configured = false

        @master = null

        @streams        = {}
        @stream_groups  = {}
        @root_route     = null

        @connected      = false
        @_retrying      = null

        # -- Set up logging -- #

        @log = @options.logger

        # -- create an alerts object -- #

        @alerts = new Alerts logger:@log.child(module:"alerts")

        # -- Make sure we have the proper slave config options -- #

        if @options.slave?.master
            @io = new IO @, @log.child(module:"slave_io"), @options.slave

            @io.on "connected", =>
                @alerts.update "slave_disconnected", @io.id, false
                @log.proxyToMaster(@io)

            @io.on "disconnected", =>
                @alerts.update "slave_disconnected", @io.id, true
                @log.proxyToMaster()

        @once "streams", =>
            @_configured = true

        # -- set up our stream server -- #

        @server = new Server core:@, logger:@log.child(subcomponent:"server"), config:@options

    #----------

    once_configured: (cb) ->
        if @_configured
            cb()
        else
            @once "streams", => cb()

    once_rewinds_loaded: (cb) ->
        @once_configured =>
            @log.debug "Looking for sources to load in #{ Object.keys(@streams).length } streams."
            aFunc = _u.after Object.keys(@streams).length, =>
                @log.debug "All sources are loaded."
                cb()

            # watch for each configured stream to have its rewind buffer loaded.
            obj._once_source_loaded aFunc for k,obj of @streams

    #----------

    configureStreams: (options) ->
        @log.debug "In slave configureStreams with ", options:options

        # are any of our current streams missing from the new options? if so,
        # disconnect them
        for k,obj of @streams
            console.log "calling disconnect on ", k
            obj.disconnect() unless options?[k]
            @streams.delete k

        # run through the streams we've been passed, initializing sources and
        # creating rewind buffers
        for key,opts of options
            if @streams[key]
                # existing stream...  pass it updated configuration
                @log.debug "Passing updated config to source: #{key}", opts:opts
                @streams[key].configure opts
            else
                @log.debug "Starting up stream: #{key}", opts:opts

                # HLS support?
                opts.hls = true if @options.hls

                # FIXME: Eventually it would make sense to allow a per-stream
                # value here
                opts.tz = tz(require "timezone/zones")(@options.timezone||"UTC")

                stream = @streams[key] = new Stream @, key, @log.child(stream:key), opts

                if @io
                    source = @socketSource stream
                    stream.useSource source

            # part of a stream group?
            if g = @streams[key].opts.group
                # do we have a matching group?
                sg = ( @stream_groups[ g ] ||= new Stream.StreamGroup g, @log.child stream_group:g )
                sg.addStream @streams[key]

                #@streams[key].hls_segmenter?.syncToGroup sg

            # should this stream accept requests to /?
            if opts.root_route
                @root_route = key

        # emit a streams event for any components under us that might
        # need to know
        @emit "streams", @streams

    #----------

    # Get a status snapshot by looping through each stream to return buffer
    # stats. Lets master know that we're still listening and current
    _streamStatus: (cb) ->
        status = {}

        for key,s of @streams
            status[ key ] = s._rStatus()

        cb null, status

    #----------

    socketSource: (stream) ->
        new Slave.SocketSource @, stream

    #----------

    ejectListeners: (lFunc,cb) ->
        # transfer listeners, one at a time

        @log.info "Preparing to eject listeners from slave."

        @_enqueued = []

        # -- prep our listeners -- #

        for k,s of @streams
            @log.info "Preparing #{ Object.keys(s._lmeta).length } listeners for #{ s.key }"
            @_enqueued.push [s,obj] for id,obj of s._lmeta

        # -- short-circuit if there are no listeners -- #

        if @_enqueued.length == 0
            cb?()
            return true

        # -- now send them one-by-one -- #

        sFunc = =>
            sl = @_enqueued.shift()

            if !sl
                @log.info "All listeners have been ejected."
                return cb null

            [stream,l] = sl

            # wrap the listener send in an error domain to try as
            # hard as we can to get it all there
            d = require("domain").create()
            d.on "error", (err) =>
                console.error "Handoff error: #{err}"
                @log.error "Eject listener for #{l.id} hit error: #{err}"
                d.exit()
                sFunc()

            d.run =>
                l.obj.prepForHandoff (skipHandoff=false) =>
                    # some listeners don't need handoffs
                    if skipHandoff
                        return sFunc()

                    socket = l.obj.socket
                    lopts =
                        key:        [stream.key,l.id].join("::"),
                        stream:     stream.key
                        id:         l.id
                        startTime:  l.startTime
                        client:     l.obj.client

                    # there's a chance that the connection could end
                    # after we recorded the id but before we get here.
                    # don't send in that case...
                    if socket && !socket.destroyed
                        lFunc lopts, socket, (err) =>
                            # move on to the next one...
                            sFunc()

                    else
                        @log.info "Listener #{lopts.id} perished in the queue. Moving on."
                        sFunc()

        sFunc()

    #----------

    landListener: (obj,socket,cb) ->
        # check and make sure they haven't disconnected mid-flight
        if socket && !socket.destroyed
            # create an output and attach it to the proper stream
            output = new @Outputs[ obj.client.output ] @streams[ obj.stream ],
                socket:     socket
                client:     obj.client
                startTime:  new Date(obj.startTime)

            cb null

        else
            cb "Listener disconnected in-flight"

    #----------

    # emulate a source connection, receiving data via sockets from our master server

    class @SocketSource extends require("events").EventEmitter
        constructor: (@slave,@stream) ->
            @log = @stream.log.child subcomponent:"socket_source"

            @log.debug "created SocketSource for #{@stream.key}"

            @slave.io.on "audio:#{@stream.key}", (chunk) =>
                @emit "data", chunk

            @slave.io.on "hls_snapshot:#{@stream.key}", (snapshot) =>
                @emit "hls_snapshot", snapshot

            @_streamKey = null

            @slave.io.vitals @stream.key, (err,obj) =>
                @_streamKey = obj.streamKey
                @_vitals    = obj
                @emit "vitals", obj

        #----------

        vitals: (cb) ->
            _vFunc = (v) =>
                cb? null, v

            if @_vitals
                _vFunc @_vitals
            else
                @once "vitals", _vFunc

        #----------

        getStreamKey: (cb) ->
            if @_streamKey
                cb? @_streamKey
            else
                @once "vitals", => cb? @_streamKey

        #----------

        getHLSSnapshot: (cb) ->
            @slave.io.hls_snapshot @stream.key, cb

        #----------

        getRewind: (cb) ->
            # connect to the master's StreamTransport and ask for any rewind
            # buffer that is available

            gRT = setTimeout =>
                @log.debug "Failed to get rewind buffer response."
                cb? "Failed to get a rewind buffer response."
            , 15000

            # connect to: @master.options.host:@master.options.port

            # GET request for rewind buffer
            @log.debug "Making Rewind Buffer request for #{@stream.key}", sock_id:@slave.io.id
            req = HTTP.request
                hostname:   @slave.io.io.io.opts.host
                port:       @slave.io.io.io.opts.port
                path:       "/s/#{@stream.key}/rewind"
                headers:
                    'stream-slave-id':    @slave.io.id
            , (res) =>
                clearTimeout gRT

                @log.debug "Got Rewind response with status code of #{ res.statusCode }"
                if res.statusCode == 200
                    # emit a 'rewind' event with a callback to get the response
                    cb? null, res

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
