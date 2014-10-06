
module.exports = class MemoryStore extends require("./base_store")
    constructor: (@max_length = null) ->
        @buffer = []

    #----------

    reset: (cb) ->
        @buffer = []
        cb? null

    #----------

    length: ->
        @buffer.length

    #----------

    at: (offset,cb) ->
        offset = @buffer.length - 1 if offset > @buffer.length
        offset = 0 if offset < 0

        cb null, @buffer[ @buffer.length - 1 - offset ]

    #----------

    range: (offset,length,cb) ->
        offset = @buffer.length - 1 if offset > @buffer.length
        offset = 0 if offset < 0

        length = offset if length > offset

        start = @buffer.length - offset
        end = start + length

        cb null, @buffer.slice(start,end)

    #----------

    first: ->
        @buffer[0]

    last: ->
        @buffer[ @buffer.length - 1 ]

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