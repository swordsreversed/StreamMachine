_ = require "underscore"

module.exports = class HLSIndex
    constructor: (@stream,@tz,@group) ->
        @_shouldRun = false
        @_running   = false

        @_segment_idx       = {}
        @_segments          = []
        @_segment_length    = null

        @header = null
        @_index  = null

    loadSnapshot: (snapshot) ->
        if snapshot
            @_segments          = snapshot.segments
            @_segment_duration  = snapshot.segment_duration
            @queueIndex()

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

        # clone the segments array, in case it changes while we're running
        segs = @_segments.slice(0)

        if segs.length < 3
            # not enough buffer for a playlist yet
            @header = null
            @_index  = null

            _after()
            return false

        # -- build our header -- #

        head = new Buffer """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:#{@_segment_duration}
        #EXT-X-MEDIA-SEQUENCE:#{segs[2].id}
        #EXT-X-DISCONTINUITY-SEQUENCE:#{segs[2].discontinuitySeq}
        #EXT-X-ALLOW-CACHE:NO

        """

        # run through segments and build the index
        # We skip the first three segments for the index, but we'll use
        # segment #2 for our next ts

        idx_segs = []

        # -- special handling for our first segment -- #

        if segs[2].discontinuitySeq == segs[1].discontinuitySeq
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

        dseq = segs[2].discontinuitySeq

        for seg in segs[3..-1]
            # is the segment where we expect it in the timeline?
            if seg.discontinuitySeq == dseq
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
                #EXT-X-PROGRAM-DATE-TIME:#{@tz(seg.ts,"%FT%T.%3N%:z")}
                /#{@stream.key}/ts/#{seg.id}.#{@stream.opts.format}
                """

                dseq = seg.discontinuitySeq

        # -- build the segment map -- #

        seg_map = {}
        for s in segs
            seg_map[ s.id ] = s

        # -- set these as active -- #

        @header = head
        @_index = idx_segs
        @_segment_idx = seg_map

        _after()

    #----------

    index: (session) ->
        session = if session then new Buffer(session+"\n") else new Buffer("\n")

        if !@header
            return false

        b = [@header]
        b.push seg,session for seg in @_index
        return Buffer.concat(b).toString()

    #----------

    pumpSegment: (rewinder,id,cb) ->
        # given a segment id, look the segment up in our store to get start ts
        # and duration, then ask the RewindBuffer for the appropriate data

        if s = @_segment_idx[ Number(id) ]
            # valid segment...
            dur = @stream.secsToOffset s.duration / 1000
            @stream.pumpFrom rewinder, s.ts_actual, dur, false, cb
        else
            cb "Segment not found in index."
