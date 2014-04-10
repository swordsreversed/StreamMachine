_u = require "underscore"
http = require "http"
url = require "url"

module.exports = class Preroller
    constructor: (@stream,@key,uri,cb) ->
        @_counter = 1

        # make sure this is a valid URI
        @uri = url.parse uri

        if @uri.protocol != "http:"
            cb? "Preroller only supports HTTP connections."
            return false

        # -- need to look at the stream to get characteristics -- #

        @stream.log.debug "Preroller calling getStreamKey"

        @stream.getStreamKey (@streamKey) =>
            @uri.path = [@uri.path,@key,@streamKey].join("/").replace(/\/\//g,"/")
            @stream.log.debug "Preroller: Stream key is #{@streamKey}. URI is #{@_uri}"

        cb? null, @

    #----------

    pump: (socket,writer,cb) ->
        cb = _u.once(cb)
        aborted = false
        # short-circuit if we haven't gotten a stream key yet
        if !@streamKey || !@uri
            cb?()
            return true

        # short-circuit if the socket has already disconnected
        if socket.destroyed
            cb?()
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
            cb?()
        , 5*1000)

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