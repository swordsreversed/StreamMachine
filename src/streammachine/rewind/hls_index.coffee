_ = require "underscore"

module.exports = class HLSIndex
    constructor: (@stream,@segmenter,@tz,@group) ->
        @_shouldRun = false
        @_running   = false

        @header = null
        @_index  = null

        _bounce_queue = _.debounce =>
            @queueIndex()
        , 1000

        @segmenter.on "remove", (seg) =>
            _bounce_queue()

        @segmenter.on "add", (seg) =>
            _bounce_queue()

        _bounce_queue()

    queueIndex: ->
        @_shouldRun = true
        @_runIndex()

    _runIndex: ->
        return false if @_running || !@stream

        @_running   = true
        @_shouldRun = false

        _after = =>
            # -- should we run again? -- #

            @_running = false
            @_runIndex() if @_shouldRun


        if @segmenter.segments.length < 3
            # not enough buffer for a playlist yet
            @header = null
            @_index  = null

            _after()
            return false

        segs = @segmenter.segments.slice(0)
        #console.log "_runIndex segs length is ", segs.length

        # -- build our header -- #

        head = new Buffer """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:#{@segmenter.segment_length}
        #EXT-X-MEDIA-SEQUENCE:#{segs[2].id}
        #EXT-X-ALLOW-CACHE:NO

        """

        # run through segmenter.segments and build the index
        # We skip the first three segments for the index, but we'll use
        # segment #2 for our next ts

        idx_segs = []

        # -- special handling for our first segment -- #

        if segs[2].id - 1 == segs[1].id
            # no discontinuity
            idx_segs.push new Buffer """
            #EXTINF:#{segs[2].duration / 1000},
            #EXT-X-PROGRAM-DATE-TIME:#{@tz(segs[2].ts,"%FT%T.%3N%:z")}
            /#{@stream.key}/ts/#{segs[2].id}.#{@stream.opts.format}
            """

        else
            # discontinuity
            idx_segs.push new Buffer """
            #EXT-X-DISCONTINUITY
            #EXTINF:#{segs[2].duration / 1000},
            #EXT-X-PROGRAM-DATE-TIME:#{@tz(segs[2].ts,"%FT%T.%3N%:z")}
            /#{@stream.key}/ts/#{segs[2].id}.#{@stream.opts.format}
            """

        # -- loop through remaining segments -- #

        last_id = segs[2].id

        for seg in segs[3..-1]
            # is the segment where we expect it in the timeline?
            #console.log "Seg ts / Last seg ts ", seg.ts, last_end_ts
            if seg.id - 1 == last_id
                # yes...

                idx_segs.push new Buffer """
                #EXTINF:#{seg.duration / 1000},
                /#{@stream.key}/ts/#{seg.id}.#{@stream.opts.format}
                """

            else
                # no... mark discontinuity

                idx_segs.push new Buffer """
                #EXT-X-DISCONTINUITY
                #EXTINF:#{seg.duration / 1000},
                #EXT-X-PROGRAM-DATE-TIME:#{@tz(Number(seg.end_ts)-seg.duration,"%FT%T.%3N%:z")}
                /#{@stream.key}/ts/#{seg.id}.#{@stream.opts.format}
                """

            last_id = seg.id

        # -- set these as active -- #

        @header = head
        @_index = idx_segs

        _after()

    #----------

    index: (session) ->
        session = if session then new Buffer(session+"\n") else new Buffer("\n")

        if !@header
            return false

        b = [@header]
        b.push seg,session for seg in @_index
        return Buffer.concat(b).toString()
