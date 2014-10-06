
module.exports = class MemoryStore extends require("./base_store")
    constructor: (@max_length = null) ->
        @buffer = []

    #----------

    reset: (cb) ->
        @buffer = []
        cb? null

    setMax: (l) ->
        @max_length = l
        @_truncate()

    #----------

    length: ->
        @buffer.length

    #----------

    at: (offset) ->
        offset = @buffer.length - 1 if offset > @buffer.length
        offset = 0 if offset < 0

        @buffer[ @buffer.length - 1 - offset ]

    first: ->
        @at( @buffer.length - 1 )

    last: ->
        @at 0

    #----------

    clone: (cb) ->
        buf_copy = @buffer.slice(0)
        cb null, buf_copy

    #----------

    insert: (chunk) ->
        fb = @buffer[ 0 ]
        lb = @buffer[ @buffer.length - 1 ]

        fb = Number(fb.ts) if fb
        lb = Number(lb.ts) if lb
        cts = Number(chunk.ts)

        if !lb || cts > lb
            # append
            @buffer.push chunk
            @emit "push", chunk

        else if cts < fb
            # prepend
            @buffer.unshift chunk
            @emit "unshift", chunk

        else
            # need to insert in the middle.
            console.error "PUSH IN MIDDLE NOT IMPLEMENTED"

        @_truncate()

        true

    #----------

    _truncate: ->
        # -- should we remove? -- #

        while @max_length && @buffer.length > @max_length
            b = @buffer.shift()
            @emit "shift", b

    #----------

    info: ->

    #----------