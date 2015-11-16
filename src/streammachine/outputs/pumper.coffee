module.exports = class Pumper
    constructor: (@stream,@opts) ->
        super "pumper"

        # figure out what we're pulling
        @stream.listen @,
            offsetSecs: @req.param("from") || @req.param("pump")
            pump:       @req.param("pump")
            pumpOnly:   true
        , (err,playHead) =>
            if err
                @opts.res.status(500).end err
                return false

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

            @opts.res.on "finish", =>
                playHead.disconnect()

            @res.on "close",    => playHead.disconnect()
            @res.on "end",      => playHead.disconnect()