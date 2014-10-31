_ = require "underscore"

# -- HTTP Live Streaming Segmenter -- #

# each segment would include:
# id:       timestamp
# duration: cumulative timestamp
# buffers:  array of buffer refs
# header:   computed ID3 header

module.exports = class HLSSegmenter
    constructor: (@rewind,@segment_length,@log) ->
        @segments       = []
        @_segments      = []
        @segment_idx    = {}

        # The RewindBuffer can get data simultaneously inserted from two
        # directions.  New live data will be emitted as an rpush and will
        # go forward in timestamp.  Loading buffer data will be emitted
        # as an runshift and will go backward in time. We need to listen
        # and construct segments for each.

        @_qRunning = false
        @_q = []

        @rewind.on "rpush",     (c) => @_queueChunk c
        @rewind.on "runshift",  (c) => @_queueChunk c

        @rewind.on "rshift", (chunk) =>
            # Data is being removed from the rewind buffer.  we should
            # clean up our segments as needed

            if (f_s = @_segments[0])? && chunk.ts > f_s.ts
                @_segments.shift()
                if (i = @segments.indexOf(f_s)) > -1
                    @segments.splice(i,1)
                    delete @segment_idx[f_s.id]

    #----------

    status: ->
        status =
            hls_segments:       @segments.length
            hls_first_seg_id:   @segments[0]?.id
            hls_first_seg_ts:   @segments[0]?.ts
            hls_last_seg_id:    @segments[ @segments.length - 1 ]?.id
            hls_last_seg_ts:    @segments[ @segments.length - 1 ]?.ts

    #----------

    _queueChunk: (c) ->
        @_q.push c
        @_runQueue()

    #----------

    _runQueue: ->
        @_qRunning = true

        if @_q.length > 0
            c = @_q.shift()
            @_inject c, => @_runQueue
        else
            @_qRunning = false

    #----------

    _inject: (chunk,cb) ->
        # do we have a segment that this chunk should go into?
        last_seg    = @_segments[ @_segments.length - 1 ]
        first_seg   = @_segments[ 0 ]

        if last_seg && ( last_seg.ts <= chunk.ts < last_seg.end_ts )
            # in our chunk going forward
            last_seg.buffers.push chunk
            return cb()

        else if first_seg && ( first_seg.ts <= chunk.ts < first_seg.end_ts )
            # in our chunk going backward
            first_seg.buffers.unshift chunk
            return cb()

        else if !last_seg || (chunk.ts >= last_seg.end_ts)
            # create a new segment for it
            seg = @_createSegment chunk.ts
            seg.buffers.push chunk

            @_segments.push seg

            # check whether the segment before ours should be finalized
            l = @_segments.length

            if l > 2
                @_finalizeSegment @_segments[l-2], cb
            else
                cb()

            return true

        else if chunk.ts < first_seg.ts
            # create a new segment for it
            seg = @_createSegment chunk.ts
            seg.buffers.push chunk

            @_segments.unshift seg

            # check whether the segment after ours should be finalized
            if @_segments.length > 2
                @_finalizeSegment @_segments[1], cb
            else
                cb()

            return true

        else
            console.log "Unsure placement. ", chunk, last_seg, first_seg

            @log.error "Not sure where to place segment!!! ", chunk_ts: chunk.ts

    #----------

    _createSegment: (ts) ->
        seg_id = Math.floor( Number(ts) / 1000 / @segment_length )

        id:         seg_id
        ts:         new Date( seg_id * 1000 * @segment_length )
        end_ts:     new Date( seg_id * 1000 * @segment_length + (@segment_length * 1000))
        buffers:    []

    #----------

    _finalizeSegment: (segment,cb) ->
        duration = 0
        segment.data        = Buffer.concat( _(segment.buffers).chain().sortBy("ts").collect((b) -> duration += b.duration; b.data).value() )
        segment.duration    = duration
        segment.header      = null

        delete segment.buffers

        # add the segment to our finalized list
        if !@segments[0] || segment.ts < @segments[0].ts
            @segments.unshift segment
        else
            @segments.push segment

        # add the segment to our index lookup
        @segment_idx[ segment.id ] = segment

        cb()

    #----------

    pumpSegment: (id,cb) ->
        if seg = @segment_idx[ id ]
            cb null, seg
        else
            cb new Error "HTTP Live Streaming segment not found."

#----------