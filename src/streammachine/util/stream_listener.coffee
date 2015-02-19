Icecast = require "icecast"
http = require "http"

module.exports = class StreamListener extends require("events").EventEmitter
    constructor: (@host,@port,@stream,@shoutcast=false) ->
        @bytesReceived = 0

        @url = "http://#{@host}:#{@port}/#{@stream}"

        @req = null
        @res = null

        @disconnected = false

    #----------

    connect: (cb) ->
        @once "connected", =>

        connect_func = if @shoutcast then Icecast.get else http.get

        @req = connect_func @url, (res) =>
            @res = res

            if res.statusCode != 200
                cb new Error("Non-200 Status code: #{ res.statusCode }")
                return false

            cb?()
            @emit "connected"

            # -- listen for data -- #

            @res.on "metadata", (meta) =>
                @emit "metadata", Icecast.parse(meta)

            @res.on "readable", =>
                @bytesReceived += data.length while data = @res.read()

            # -- listen for an early exit -- #

            @res.once "error", =>
                @emit "error" if !@disconnected

            @res.once "close", =>
                @emit "close" if !@disconnected

    #----------

    disconnect: (cb) ->
        @disconnected = true
        @res.socket.destroy()
        cb?()