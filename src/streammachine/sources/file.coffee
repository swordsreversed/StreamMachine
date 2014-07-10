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

        @start() if !@opts.do_not_emit

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

    start: ->
        return true if @_int

        @_int = setInterval =>
            @_emitOnce()
        , @emitDuration * 1000

        true

    #----------

    stop: ->
        return true if !@_int

        clearInterval @_int
        @_int = null

        true

    #----------

    _emitOnce: (ts=null) ->
        @_emit_pos = 0 if @_emit_pos >= @_chunks.length

        chunk = @_chunks[ @_emit_pos ]

        return if !chunk

        console.log "NO DATA!!!! ", chunk if !chunk.data

        @emit "data",
            data:       chunk.data
            ts:         ts || (new Date)
            duration:   chunk.duration
            streamKey:  @streamKey
            uuid:       @uuid

        @_emit_pos = @_emit_pos + 1

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