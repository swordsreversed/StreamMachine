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

            index = @opts.idx.index(session_info)

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
                    @opts.res.write """
                    #EXT-X-STREAM-INF:BANDWIDTH=#{s.opts.bandwidth},CODECS="#{s.opts.codec}"\n
                    """
                    url =
                        if @client.pass_session
                            "/#{s.key}.m3u8?session_id=#{@client.session_id}"
                        else
                            "/#{s.key}.m3u8"

                    @opts.res.write url + "\n"

                @opts.res.end()
