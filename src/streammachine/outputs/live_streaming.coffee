_ = require "underscore"

module.exports = class LiveStreaming
    @secs_per_ts = 10

    constructor: (@stream,@opts) ->
        @chunks_per_ts = LiveStreaming.secs_per_ts / @stream._rsecsPerChunk

        # we'll have received a sequence number in req.param("seq"). If we
        # multiply it by LiveStreaming.secs_per_ts and then by 1000, we'll
        # have a timestamp in ms. We need to check if that ts is in our
        # rewind buffer.  If so, we need to find it and return a chunk of
        # data @chunks_per_ts chunks long.

        console.log "looking for ", @opts.req.param("seq")

        seq_date = new Date( @opts.req.param("seq") * LiveStreaming.secs_per_ts * 1000 )

        console.log "seq_date is ", seq_date

        @stream.listen @,
            timestamp:  seq_date
            pump:       LiveStreaming.secs_per_ts
            pumpOnly:   true
        , (err,playHead) =>
            if err
                @opts.res.status(500).end err
                return false

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

        @opts.res.status(200).end "OK"

    #----------

    class @Index
        constructor: (@stream,@opts) ->
            @chunks_per_ts = LiveStreaming.secs_per_ts / @stream._rsecsPerChunk

            # take a look at the rewind buffer to see how many chunks we
            # should be presenting to the listener.
            first_buffer = @stream._rbuffer[0]

            if !first_buffer
                @opts.res.writeHead 500, {}
                @opts.res.end "No data."
                return false

            #console.log "first ts is ", first_buffer.ts
            # We'll use the timestamp of the first chunk to compute a
            # sequence number, which needs to increment for each ts
            # and always be computed the same way
            first_chunk = Math.floor( Number(first_buffer.ts) / 1000 )

            # we need to start from an even seconds bound
            first_seq = Math.ceil( first_chunk / LiveStreaming.secs_per_ts )

            # what's our newest segment?
            #console.log "last ts is ", @stream._rbuffer[ @stream._rbuffer.length - 1 ].ts
            last_chunk = Math.floor( Number(@stream._rbuffer[ @stream._rbuffer.length - 1 ].ts) / 1000 )
            last_seq = Math.floor( last_chunk / LiveStreaming.secs_per_ts )

            @opts.res.writeHead 200,
                "Content-type": "application/x-mpegURL"

            @opts.res.write """
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-TARGETDURATION:#{LiveStreaming.secs_per_ts}
            #EXT-X-MEDIA-SEQUENCE:#{first_seq}

            """

            for seq in [first_seq..last_seq]
                @opts.res.write """
                #EXTINF:#{LiveStreaming.secs_per_ts}
                http://#{@stream.host}/#{@stream.key}/ts/#{seq}

                """

            @opts.res.end()
