_u = require "underscore"
uuid = require "node-uuid"

module.exports = class Source extends require("events").EventEmitter

    #----------

    constructor: (source_opts={}) ->
        @uuid = @opts.uuid || uuid.v4()

        @isFallback = false
        @streamKey  = null
        @_vitals    = null

        @_chunk_queue = []
        @_chunk_queue_ts = null

        # If not specified, we'll emit chunks of data every 0.5 seconds
        @emitDuration = @opts.chunkDuration || 0.5

        @log = @opts.logger?.child uuid:@uuid

        @parser = new (require "../parsers/#{@opts.format}")

        if source_opts.useHeartbeat
            # -- Alert if data stops flowing -- #

            # creates a sort of dead mans switch that we use to kill the connection
            # if it stops sending data
            @_pingData = _u.debounce =>
                # data has stopped flowing. kill the connection.
                @log?.info "Source data stopped flowing.  Killing connection."
                @disconnect()

            , 30*1000


        # -- Pull vitals from first header -- #

        @parser.once "header", (header) =>
            # -- compute frames per second and stream key -- #

            @framesPerSec   = header.frames_per_sec
            @streamKey      = header.stream_key

            @log?.debug "setting framesPerSec to ", frames:@framesPerSec
            @log?.debug "first header is ", header

            # -- send out our stream vitals -- #

            @_setVitals
                streamKey:          @streamKey
                framesPerSec:       @framesPerSec
                emitDuration:       @emitDuration

        # -- Turn data frames into chunks -- #

        @parser.on "frame", (frame) =>
            # heartbeat?
            @_pingData?()

            # -- queue up frames until we get to @emitDuration -- #
            @_chunk_queue.push frame

            if !@_chunk_queue_ts
                @_chunk_queue_ts = (new Date)

            if @framesPerSec && ( @_chunk_queue.length / @framesPerSec > @emitDuration )
                len = 0
                len += b.length for b in @_chunk_queue

                # make this into one buffer
                buf = new Buffer(len)
                pos = 0

                for fb in @_chunk_queue
                    fb.copy(buf,pos)
                    pos += fb.length

                buf_ts = @_chunk_queue_ts

                duration = (@_chunk_queue.length / @framesPerSec)

                # reset chunk array
                @_chunk_queue.length = 0
                @_chunk_queue_ts = (new Date)

                @emit "_chunk",
                    data:       buf
                    ts:         (new Date)
                    duration:   duration
                    streamKey:  @streamKey
                    uuid:       @uuid

    #----------

    getStreamKey: (cb) ->
        if @streamKey
            cb? @streamKey
        else
            @once "vitals", => cb? @_vitals.streamKey

    #----------

    _chunkFrames: ->


    #----------

    _setVitals: (vitals) ->
        @_vitals = vitals
        @emit "vitals", @_vitals

    vitals: (cb) ->
        if @_vitals
            cb? @_vitals
        else
            @once "vitals", => cb? @_vitals
