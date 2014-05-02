_   = require "underscore"
tz  = require "timezone"
uuid = require "node-uuid"

BaseOutput = require "./base"

module.exports = class LiveStreaming extends BaseOutput
    @secs_per_ts = 10

    constructor: (@stream,@opts) ->

        super "live_streaming"

        @chunks_per_ts = LiveStreaming.secs_per_ts / @stream._rsecsPerChunk

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
                @opts.res.status(404).end "Segment not found."
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

    class @Index extends BaseOutput
        constructor: (@stream,@opts) ->
            @stream._once_source_loaded =>
                if @stream.hls_segmenter.segments.length <= 3
                    @opts.res.status(500).end "No data."
                    return false

                segments = @stream.hls_segmenter.segments[2..-1]

                super "live_streaming"

                # requests for a stream index should hopefully come in with a
                # session id attached.  If so, we'll proxy it through to the URLs
                # for the ts files.

                session_id = @opts.req.param("session_id")

                @opts.res.writeHead 200,
                    "Content-type": "application/vnd.apple.mpegurl"

                @opts.res.write """
                #EXTM3U
                #EXT-X-VERSION:3
                #EXT-X-TARGETDURATION:#{LiveStreaming.secs_per_ts}
                #EXT-X-MEDIA-SEQUENCE:#{segments[0].id}
                #EXT-X-ALLOW-CACHE:NO

                """

                # List all segments, skipping the first three (so that we don't
                # deliver an index and then expire the segment a second later)
                for seg in segments
                    seg_record = seg.index_record ||= """
                    #EXTINF:#{seg.duration},#{@stream.StreamTitle}
                    #EXT-X-PROGRAM-DATE-TIME:#{tz(seg.ts,"%FT%T.%3N%:z")}
                    http://#{@stream.opts.host}/#{@stream.key}/ts/#{seg.id}.#{@stream.opts.format}
                    """

                    @opts.res.write seg_record + ( (session_id && "?session_id=#{session_id}") || "" ) + "\n"

                @opts.res.end()

    #----------

    class @GroupIndex extends BaseOutput
        constructor: (@group,@opts) ->

            super "live_streaming"

            @opts.res.writeHead 200,
                "Content-type": "application/vnd.apple.mpegurl"

            # who do we ask for the session id?
            @group.startSession @client, (err,session_id) =>
                @opts.res.write """
                #EXTM3U

                """

                for key,s of @group.streams
                    @opts.res.write """
                    #EXT-X-STREAM-INF:BANDWIDTH=#{s.opts.bandwidth},CODECS="#{s.opts.codec}"
                    http://#{s.opts.host}/#{s.key}.m3u8?session_id=#{session_id}

                    """

                @opts.res.end()