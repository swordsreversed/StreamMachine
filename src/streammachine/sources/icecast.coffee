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
        super useHeartbeat:true

        # data is going to start streaming in as data on req. We need to pipe
        # it into a parser to turn it into frames, headers, etc

        @log?.debug "New Icecast source."

        # incoming -> Parser
        @opts.sock.pipe @parser

        @last_ts = null

        # outgoing -> Stream
        @on "_chunk", (chunk) ->
            @last_ts = chunk.ts
            @emit "data", chunk

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
        last_ts:    @last_ts

    #----------

    disconnect: ->
        if @connected
            @opts.sock.destroy()
            @opts.sock.removeAllListeners()
            @connected = false
            @emit "disconnect"