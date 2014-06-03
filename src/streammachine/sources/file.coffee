fs = require "fs"
_ = require "underscore"

# FileSource emulates a stream source by reading a local audio file in a
# loop at the correct audio speed.

module.exports = class FileSource extends require("./base")
    TYPE: -> "File (#{@opts.filePath})"

    constructor: (@opts) ->
        super()

        @connected = false

        @_file = null

        @_chunks = []

        @_emit_pos = 0

        @_int = setInterval =>
            @_emit_pos = 0 if @_emit_pos >= @_chunks.length

            chunk = @_chunks[ @_emit_pos ]

            return if !chunk

            console.log "NO DATA!!!! ", chunk if !chunk.data

            @emit "data",
                data:       chunk.data
                ts:         (new Date)
                duration:   chunk.duration
                streamKey:  @streamKey
                uuid:       @uuid

            @_emit_pos = @_emit_pos + 1

        , @emitDuration * 1000

        @on "_chunk", (chunk) =>
            @_chunks.push chunk

        @parser.once "header", (header) =>
            @connected = true
            @emit "connect"

        @parser.once "end", =>
            # done parsing...
            @parser.removeAllListeners()
            @_current_chunk = null
            @emit "_loaded"

        # pipe our file into the parser
        @_file = fs.createReadStream @opts.filePath
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