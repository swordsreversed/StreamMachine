Icecast = require "icecast"
http = require "http"

debug = require("debug")("sm:util:stream_listener")
_ = require "underscore"

module.exports = class StreamListener extends require("events").EventEmitter
    constructor: (@host,@port,@stream,@shoutcast=false) ->
        @bytesReceived = 0

        @url = "http://#{@host}:#{@port}/#{@stream}"

        @req = null
        @res = null

        debug "Created new Stream Listener for #{@url}"

        @disconnected = false

    #----------

    connect: (cb) ->
        @once "connected", =>

        connect_func = if @shoutcast then Icecast.get else http.get

        @req = connect_func @url, (res) =>
            @res = res

            debug "Connected. Response code is #{ res.statusCode }."

            if res.statusCode != 200
                cb new Error("Non-200 Status code: #{ res.statusCode }")
                return false

            cb?()
            @emit "connected"

            # -- listen for data -- #

            @res.on "metadata", (meta) =>
                @emit "metadata", Icecast.parse(meta)

            @res.on "readable", =>
                while data = @res.read()
                    @bytesReceived += data.length
                    @emit "bytes"

            # -- listen for an early exit -- #

            @res.once "error", (err) =>
                debug "Listener connection error: #{err}"
                @emit "error" if !@disconnected

            @res.once "close", =>
                debug "Listener connection closed."

                @emit "close" if !@disconnected

        @req.once "socket", (sock) => @emit "socket", sock

    #----------

    disconnect: (cb) ->
        @disconnected = true
        @res.socket.destroy()
        cb?()
