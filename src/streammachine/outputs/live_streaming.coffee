_   = require "underscore"
tz  = require "timezone"
uuid = require "node-uuid"

BaseOutput = require "./base"

module.exports = class LiveStreaming extends BaseOutput
    constructor: (@stream,@opts) ->

        super "live_streaming"

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
            super "live_streaming"

            session_info = if @client.session_id && @client.pass_session
               "?session_id=#{@client.session_id}"

            # HACK: This is needed to get ua information on segments until we
            # can fix client ua for AppleCoreMedia
            if @opts.req.param("ua")
                session_info = if session_info then "#{session_info}&ua=#{@opts.req.param("ua")}" else "?ua=#{@opts.req.param("ua")}"

            index = @stream.hls.index(session_info) if @stream.hls

            if index
                @opts.res.writeHead 200,
                    "Content-type": "application/vnd.apple.mpegurl"

                @opts.res.end index

            else
                @opts.res.status(500).end "No data."

    #----------

    class @GroupIndex extends BaseOutput
        constructor: (@group,@opts) ->

            super "live_streaming"

            @opts.res.writeHead 200,
                "Content-type": "application/vnd.apple.mpegurl"

            # who do we ask for the session id?
            @group.startSession @client, (err) =>
                @opts.res.write """
                #EXTM3U

                """

                for key,s of @group.streams
                    url = "/#{s.key}.m3u8"
                    session_bits = []

                    if @client.pass_session
                        session_bits.push "session_id=#{@client.session_id}"

                    if @opts.req.param("ua")
                        session_bits.push "ua=#{@opts.req.param("ua")}"

                    if session_bits.length > 0
                        url = "#{url}?#{session_bits.join("&")}"

                    @opts.res.write """
                    #EXT-X-STREAM-INF:BANDWIDTH=#{s.opts.bandwidth},CODECS="#{s.opts.codec}"
                    #{url}\n
                    """

                @opts.res.end()
