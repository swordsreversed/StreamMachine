fs = require "fs"
_ = require "underscore"

# FileSource emulates a stream source by reading a local audio file in a
# loop at the correct audio speed.

module.exports = class FileSource extends require("./base")
    TYPE: -> "File (#{@filePath})"

    constructor: (@stream,@filePath) ->
        super()

        @connected = false

        @emitDuration  = 0.5

        @_file = null

        # open a parser based on our stream's format
        @parser = @_new_parser()

        @_chunks = []
        @_current_chunk = []
        @_chunks.push @_current_chunk

        @_last_header = null
        @_emit_pos = 0

        @_int = setInterval =>
            @_emit_pos = 0 if @_emit_pos >= @_chunks.length

            chunk = @_chunks[ @_emit_pos ]

            buf = null
            duration = null

            if _.isArray(chunk)

                # -- create a new buffer -- #

                len = 0
                len += b.length for b in chunk

                # make this into one buffer
                buf = new Buffer(len)
                pos = 0

                for fb in chunk
                    fb.copy(buf,pos)
                    pos += fb.length

                duration = (chunk.length / @framesPerSec)

                # -- should we stash this in the chunks array? -- #

                if chunk != @_current_chunk
                    @_chunks[ @_emit_pos ] =
                        buffer:     buf
                        duration:   duration

            else
                # already prepared as a buffer
                buf         = chunk.buffer
                duration    = chunk.duration

            @emit "data",
                data:       buf
                ts:         (new Date)
                duration:   duration
                streamKey:  @streamKey
                uuid:       @uuid

            @_emit_pos = @_emit_pos + 1

        , @emitDuration * 1000

        @parser.on "frame", (frame) =>
            @_current_chunk.push frame

            if @framesPerSec && ( @_current_chunk.length / @framesPerSec > @emitDuration )
                @_current_chunk = []
                @_chunks.push @_current_chunk

        # first header: set our stream key and speed
        @parser.once "header", (header) =>
            # -- compute frames per second and stream key -- #

            @framesPerSec   = header.frames_per_sec
            @streamKey      = header.stream_key

            @log.debug "setting framesPerSec to ", frames:@framesPerSec
            @log.debug "first header is ", header

            # -- send out our stream vitals -- #

            @_setVitals
                streamKey:          @streamKey
                framesPerSec:       @framesPerSec
                emitDuration:       @emitDuration

            @connected = true
            @emit "connect"

        @parser.once "end", =>
            # done parsing...
            @parser.removeAllListeners()
            @_current_chunk = null

        # pipe our file into the parser
        @_file = fs.createReadStream @filePath
        @_file.pipe(@parser)

    #----------

    info: ->
        source:     @TYPE?() ? @TYPE
        uuid:       @uuid
        filePath:   @filePath

    #----------

    disconnect: ->
        if @connected
            @connected = false
            @emit "disconnect"
            clearInterval @_int