_u = require "underscore"

module.exports = class IcecastSource extends require("./base")
    TYPE: -> "Icecast (#{[@opts.sock.remoteAddress,@opts.sock.remotePort].join(":")})"

    # opts should include:
    # format:   Format for Parser (aac or mp3)
    # sock:     Socket for incoming data
    # headers:  Headers from the source request
    # uuid:     Source UUID, if this is a handoff source (optional)
    # logger:   Logger (optional)
    constructor: (@opts) ->
        super()

        @emitDuration  = 0.5

        # -- Alert if data stops flowing -- #

        # creates a sort of dead mans switch that we use to kill the connection
        # if it stops sending data
        @_pingData = _u.debounce =>
            # data has stopped flowing. kill the connection.
            @log?.info "Source data stopped flowing.  Killing connection."
            @disconnect()

        , 30*1000

        # data is going to start streaming in as data on req. We need to pipe
        # it into a parser to turn it into frames, headers, etc

        @log?.debug "New Icecast source."

        @_chunk_queue = []
        @_chunk_queue_ts = null

        # incoming -> Parser
        @opts.sock.pipe @parser

        # outgoing -> Stream
        @parser.on "frame", (frame) =>
            @_pingData()
            @emit "frame", frame

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

                # emit new buffer
                @emit "data",
                    data:       buf
                    ts:         buf_ts
                    duration:   duration
                    streamKey:  @streamKey
                    uuid:       @uuid

        # we need to grab one frame to compute framesPerSec
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

        @opts.sock.on "close", =>
            @connected = false
            @log?.debug "Icecast source got close event"
            @emit "disconnect"
            @opts.sock.end()

        @opts.sock.on "end", =>
            @connected = false
            @log?.debug "Icecast source got end event"
            # source has gone away
            @emit "disconnect"
            @opts.sock.end()

        # return with success
        @connected = true

    #----------

    info: ->
        source:     @TYPE?() ? @TYPE
        connected:  @connected
        url:        [@opts.sock.remoteAddress,@opts.sock.remotePort].join(":")
        streamKey:  @streamKey
        uuid:       @uuid

    #----------

    disconnect: ->
        if @connected
            @opts.sock.destroy()
            @opts.sock.removeAllListeners()
            @connected = false
            @emit "disconnect"