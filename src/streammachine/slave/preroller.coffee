_u = require "underscore"
http = require "http"
url = require "url"

module.exports = class Preroller
    constructor: (@stream,@key,@uri,@transcode_uri,cb) ->
        @_counter = 1

        # -- need to look at the stream to get characteristics -- #

        @stream.log.debug "Preroller calling getStreamKey"

        @stream.getStreamKey (@streamKey) =>
            @stream.log.debug "Preroller: Stream key is #{@streamKey}. Ready to start serving."

        cb? null, @

    #----------

    pump: (client,socket,writer,cb) ->
        cb = _u.once(cb)
        aborted = false
        # short-circuit if we haven't gotten a stream key yet
        if !@streamKey || !@uri
            cb new Error("Preroll request before streamKey or missing URI.")
            return true

        # short-circuit if the socket has already disconnected
        if socket.destroyed
            cb new Error("Preroll request got destroyed socket.")
            return true

        count = @_counter++

        # If the preroll request can't be made in 5 seconds or less,
        # abort the preroll.
        # TODO: Make the timeout wait configurable
        prerollTimeout = setTimeout(=>
            @stream.log.debug "preroll request timeout. Aborting.", count
            req.abort()
            aborted = true
            detach()
            cb new Error("Preroll request timed out.")
        , 5*1000)

        # -- Set up our ad URI -- #

        uri = @uri
            .replace("KEY", @streamKey)
            .replace("IP", client.ip)
            .replace("STREAM", @stream.key)
            .replace("UA", encodeURIComponent(client.ua))

        # -- make a request to the preroll server -- #

        @stream.log.debug "firing preroll request", count, @_uri
        req = http.get @uri, (res) =>
            @stream.log.debug "got preroll response ", count
            if res.statusCode == 200
                # stream preroll through to the output
                res.on "data", (chunk) =>
                    writer?.write(chunk)

                # when preroll is done, call the output's callback
                res.on "end", =>
                    detach()
                    cb?()
                    return true

            else
                detach()
                cb?()
                return true

        req.on "socket", (sock) =>
            @stream.log.debug "socket granted for ", count

        req.on "error", (err) =>
            if !aborted
                @stream.log.debug "got a request error for ", count, err
                detach()
                cb?()

        detach = =>
            clearTimeout(prerollTimeout) if prerollTimeout
            socket.removeListener "close", conn_pre_abort
            socket.removeListener "end", conn_pre_abort

        # attach a close listener to the response, to be fired if it gets
        # shut down and we should abort the request

        conn_pre_abort = =>
            detach()
            if socket.destroyed
                @stream.log.debug "aborting preroll ", count
                req.abort()
                aborted = true

        socket.once "close", conn_pre_abort
        socket.once "end", conn_pre_abort


    #----------

    connect: ->


    #----------

    disconnect: ->

    #----------