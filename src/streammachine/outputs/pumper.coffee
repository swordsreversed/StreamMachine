_u = require 'underscore'

module.exports = class Pumper
    constructor: (@stream,@opts) ->
        @stream = stream

        @req = @opts.req
        @res = @opts.res

        @client = output:"pumper"

        # -- set up client information -- #

        @client.ip          = @opts.req.connection.remoteAddress
        @client.path        = @opts.req.url
        @client.ua          = _u.compact([@opts.req.param("ua"),@opts.req.headers?['user-agent']]).join(" | ")
        @client.offsetSecs  = @req.param("from") || @req.param("pump")
        @client.meta_int    = @stream.opts.meta_interval

        @socket = @opts.req.connection

        # figure out what we're pulling
        @stream.listen @,
            offsetSecs: @req.param("from") || @req.param("pump")
            pump:       @req.param("pump")
            pumpOnly:   true
        , (err,playHead) =>
            playHead.once "pump", (info) =>
                console.log "In pump readable. playHead queue is ", info
                headers =
                    "Content-Type":
                        if @stream.opts.format == "mp3"         then "audio/mpeg"
                        else if @stream.opts.format == "aac"    then "audio/aacp"
                        else "unknown"
                    "Connection":           "close"
                    "Content-Length":       info.length

                # write out our headers
                @res.writeHead 200, headers

                # send our pump buffer to the client
                playHead.pipe(@res)

            @res.on "close",    => playHead.disconnect()
            @res.on "end",      => playHead.disconnect()