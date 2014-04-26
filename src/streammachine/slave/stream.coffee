_u = require "underscore"

Preroller = require "./preroller"
Rewind = require "../rewind_buffer"

# Streams are the endpoints that listeners connect to.

# On startup, a slave stream should connect to the master and start serving
# live audio as quickly as possible. It should then try to load in any
# Rewind buffer info available on the master.

module.exports = class Stream extends require('../rewind_buffer')
    constructor: (@core,@key,@log,@opts) ->
        @STATUS = "Initializing"

        # initialize RewindBuffer, with support for HTTP Live Streaming
        super liveStreaming:true

        @StreamTitle  = @opts.metaTitle
        @StreamUrl    = ""

        # remove our max listener count
        @setMaxListeners 0

        @_id_increment = 1
        @_lmeta = {}

        @preroll = null
        @mlog_timer = null

        @metaFunc = (chunk) =>
            @StreamTitle    = chunk.StreamTitle if chunk.StreamTitle
            @StreamUrl      = chunk.StreamUrl if chunk.StreamUrl

        @on "source", =>
            #@source.on "data", @dataFunc
            @source.on "meta", @metaFunc
            @source.on "buffer", (c) => @_insertBuffer(c)

            @source.once "disconnect", =>
                # try creating a new one
                @source = null
                @_buildSocketSource()

        # now run configure...
        process.nextTick => @configure(opts)

        # -- configure a source -- #

        @_buildSocketSource()

    #----------

    info: ->
        key:            @key
        status:         @STATUS
        sources:        []
        listeners:      @listeners()
        options:        @opts
        bufferedSecs:   @bufferedSecs()

    #----------

    useSource: (source) ->
        @log.debug "Slave stream got source connection"
        @source = source
        @emit "source", @source

    #----------

    _buildSocketSource: ->
        if !@source && @core.master
            @_sourceInitializing = true
            source = @core.socketSource @
            @useSource source

            # -- fetch rewind? -- #

            if @_rbuffer.length == 0
                source.getRewind (err,stream,req) =>
                    if err
                        @log.error "Source getRewind encountered an error: #{err}", error:err
                        @_sourceInitializing = false
                        @emit "_source_init"

                        return false

                    @loadBuffer stream, (err) =>
                        @log.debug "Slave source loaded rewind buffer."
                        req.end()

                        @_sourceInitializing = false
                        @emit "_source_init"

    #----------

    getStreamKey: (cb) ->
        if @source
            @source.getStreamKey cb
        else
            @once "source", =>
                @source.getStreamKey cb

    #----------

    _once_source_loaded: (cb) ->
        if @_sourceInitializing
            # wait for a source_init event
            @once "_source_init", => cb?()

        else
            # send them on through
            cb?()

    #----------

    configure: (opts) ->

        # -- Preroll -- #

        @log.debug "Preroll settings are ", preroll:opts.preroll

        if opts.preroll? && opts.preroll != ""
            # create a Preroller connection
            key = if (opts.preroll_key && opts.preroll_key != "") then opts.preroll_key else @key

            new Preroller @, key, opts.preroll, (err,pre) =>
                if err
                    @log.error "Failed to create preroller: #{err}"
                    return false

                @preroll = pre
                @log.debug "Preroller is created."

        # -- Should we be logging minutes? -- #

        if opts.log_minutes && !@mlog_timer
            # set up a timer to log minutes listened
            @mlog_timer = setInterval =>
                # run through each listener and log minute or time listened
                now = new Date
                for id,l of @_lmeta
                    # we only log requests that have lasted more than one minute.
                    # we use startTime for the length the session has been going,
                    # but use minuteTime for accumulating unlogged time
                    if ( now.getTime() / 1000 - l.startTime.getTime() / 1000 ) > 60
                        dur = ( now.getTime() / 1000 - l.minuteTime.getTime() / 1000 )
                        @log.minute "", path:l.obj.client.path, time:now, ua:l.obj.client.ua, duration:dur
                        l.minuteTime = now

            , 60*1000

        else if @mlog_timer && !opts.log_minutes
            clearInterval @mlog_timer
            @mlog_timer = null

        # -- Set up bufferSize poller -- #

        # We disconnect clients that have fallen too far behind on their
        # buffers. Buffer size can be configured via the "max_buffer" setting,
        # which takes bits
        console.log "max buffer size is ", @opts.max_buffer

        if @buf_timer
            clearInterval @buf_timer
            @buf_timer = null

        @buf_timer = setInterval =>
            all_buf = 0
            for id,l of @_lmeta
                all_buf += l.rewind._queuedBytes + l.obj.socket?.bufferSize

                if (l.rewind._queuedBytes||0) + (l.obj.socket?.bufferSize||0) > @opts.max_buffer
                    @log.debug "Connection exceeded max buffer size.", client:l.obj.client, bufferSize:l.rewind._queuedBytes
                    l.obj.disconnect(true)

            @log.debug "All buffers: #{all_buf}"
        , 60*1000

        @emit "config"

    #----------

    disconnect: ->
        # handle clearing out lmeta
        l.obj.disconnect(true) for k,l of @_lmeta

        # if we have a source, disconnect it
        if @source
            @source.disconnect()

        @emit "disconnect"

    #----------

    listeners: ->
        _u(@_lmeta).keys().length

    #----------

    listen: (obj,opts,cb) ->
        # generate a metadata hash
        lmeta =
            id:         @_id_increment++
            obj:        obj
            startTime:  opts.startTime  || (new Date)
            minuteTime: opts.minuteTime || (new Date)

        # don't ask for a rewinder while our source is going through init,
        # since we don't want to fail an offset request that should be
        # valid.
        @_once_source_loaded =>
            # get a rewinder (handles the actual broadcast)
            @getRewinder lmeta.id, opts, (err,rewind,extra...) =>
                if err
                    cb? err, null
                    return false

                lmeta.rewind = rewind

                # stash the object
                @_lmeta[ lmeta.id ] = lmeta

                # return the rewinder (so that they can change offsets, etc)
                cb? null, lmeta.rewind, extra...

    #----------

    disconnectListener: (id) ->
        lmeta = @_lmeta[id]

        if lmeta
            # -- remove from listeners -- #
            delete @_lmeta[id]

            # -- log the request's end -- #

            # compute listening duration
            seconds = null
            endTime = (new Date)
            seconds = (endTime.getTime() - lmeta.startTime.getTime()) / 1000

            # log the connection end
            @log.debug "Connection end", id:id, listeners:_u(@_lmeta).keys().length, bytes:lmeta.obj.socket?.bytesWritten, seconds:seconds

            @log.request "",
                output:     lmeta.obj.client.output
                path:       lmeta.obj.client.path
                ip:         lmeta.obj.client.ip
                ua:         lmeta.obj.client.ua
                session_id: lmeta.obj.client.session_id
                bytes:      lmeta.obj.socket?.bytesWritten
                seconds:    seconds
                time:       endTime

            true
        else
            console.error "disconnectListener called for #{id}, but no listener found."

    #----------

    class @StreamGroup extends require("events").EventEmitter
        constructor: (@key) ->
            @streams = {}

        addStream: (stream) ->
            if !@streams[ stream.key ]
                console.log "SG #{@key}: Adding stream #{stream.key}"

                @streams[ stream.key ] =
                    stream:     stream
                    bandwidth:  Number(stream.opts.bandwidth||0)
                    codec:      switch stream.opts.format
                        when "aac"
                            "mp4a.40.2"
                        when "mp3"
                            ""

                # listen in case it goes away
                delFunc = =>
                    console.log "SG #{@key}: Stream disconnected: #{ stream.key }"
                    delete @streams[ stream.key ]


                stream.on "disconnect", delFunc

                stream.on "config", =>
                    delFunc() if stream.opts.group != @key
