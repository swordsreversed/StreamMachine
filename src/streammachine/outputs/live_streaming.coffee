_   = require "underscore"
tz  = require "timezone"
uuid = require "node-uuid"

module.exports = class LiveStreaming
    @secs_per_ts = 10

    constructor: (@stream,@opts) ->
        @client = output:"live_streaming"

        @client.ip          = @opts.req.connection.remoteAddress
        @client.path        = @opts.req.url
        @client.ua          = _.compact([@opts.req.param("ua"),@opts.req.headers?['user-agent']]).join(" | ")
        @client.user_id     = @opts.req.user_id
        @client.session_id  = @opts.req.param("session")

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

            # requests for a stream index should hopefully come in with a
            # session id attached.  If so, we'll proxy it through to the URLs
            # for the ts files.

            session_id = @opts.req.param("session")

            @opts.res.writeHead 200,
                "Content-type": "application/vnd.apple.mpegurl"

            @opts.res.write """
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-TARGETDURATION:#{LiveStreaming.secs_per_ts}
            #EXT-X-MEDIA-SEQUENCE:#{@stream.hls_segmenter.segments[0].id}
            #EXT-X-ALLOW-CACHE:NO

            """

            for seg in @stream.hls_segmenter.segments
                @opts.res.write """
                #EXTINF:#{seg.duration},#{@stream.StreamTitle}
                #EXT-X-PROGRAM-DATE-TIME:#{tz(seg.ts,"%FT%T.%3N%:z")}
                http://#{@stream.opts.host}/#{@stream.key}/ts/#{seg.id}.#{@stream.opts.format}?session=#{session_id}

                """

            @opts.res.end()

    #----------

    class @GroupIndex
        constructor: (@group,@opts) ->
            @opts.res.writeHead 200,
                "Content-type": "application/vnd.apple.mpegurl"


            # we'll generate and attach a session id to each master playlist
            # request, so that we can keep track of the course of the play
            session_id = uuid.v4()

            @opts.res.write """
            #EXTM3U

            """

            for key,s of @group.streams
                @opts.res.write """
                #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=#{s.opts.bandwidth},CODECS="#{s.opts.codec}"
                http://#{s.opts.host}/#{s.key}.m3u8?session=#{session_id}

                """

            @opts.res.end()