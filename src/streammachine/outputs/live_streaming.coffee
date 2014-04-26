_   = require "underscore"
tz  = require "timezone"

module.exports = class LiveStreaming
    @secs_per_ts = 10

    constructor: (@stream,@opts) ->
        @client = output:"live_streaming"

        @client.ip          = @opts.req.connection.remoteAddress
        @client.path        = @opts.req.url
        @client.ua          = _.compact([@opts.req.param("ua"),@opts.req.headers?['user-agent']]).join(" | ")
        @client.session_id  = @opts.req.session?.sessionID

        @chunks_per_ts = LiveStreaming.secs_per_ts / @stream._rsecsPerChunk

        @socket = @opts.req.connection

        # we'll have received a sequence number in req.param("seq"). If we
        # multiply it by LiveStreaming.secs_per_ts and then by 1000, we'll
        # have a timestamp in ms. We need to check if that ts is in our
        # rewind buffer.  If so, we need to find it and return a chunk of
        # data @chunks_per_ts chunks long.

        @stream.listen @,
            live_segment:   @opts.req.param("seg")
            pumpOnly:       true
        , (err,playHead,info) =>
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
            @opts.res.writeHead 200, headers

            # send our pump buffer to the client
            playHead.pipe(@opts.res)

            @opts.res.on "finish", =>
                playHead.disconnect()

            @opts.res.on "close",    => playHead.disconnect()
            @opts.res.on "end",      => playHead.disconnect()

    #----------

    class @Index
        constructor: (@stream,@opts) ->
            if @stream.hls_segmenter.segments.length == 0
                @opts.res.writeHead 500, {}
                @opts.res.end "No data."
                return false

            @opts.res.writeHead 200,
                "Content-type": "application/vnd.apple.mpegurl"

            @opts.res.write """
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-TARGETDURATION:#{LiveStreaming.secs_per_ts}
            #EXT-X-MEDIA-SEQUENCE:#{@stream.hls_segmenter.segments[0].id}
            #EXT-X-ALLOW-CACHE:YES

            """

            for seg in @stream.hls_segmenter.segments
                @opts.res.write """
                #EXTINF:#{seg.duration},#{@stream.StreamTitle}
                #EXT-X-PROGRAM-DATE-TIME:#{tz(seg.ts,"%FT%T.%3N%:z")}
                http://#{@stream.opts.host}/#{@stream.key}/ts/#{seg.id}.#{@stream.opts.format}

                """

            @opts.res.end()

    class @GroupIndex
        constructor: (@group,@opts) ->
            @opts.res.writeHead 200,
                "Content-type": "application/vnd.apple.mpegurl"


            @opts.res.write """
            #EXTM3U

            """

            for key,s of @group.streams
                @opts.res.write """
                #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=#{s.bandwidth},CODECS="#{s.codec}"
                http://#{s.stream.opts.host}/#{s.stream.key}.m3u8

                """

            @opts.res.end()