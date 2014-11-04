_ = require "underscore"
tz      = require 'timezone'

# -- HTTP Live Streaming Segmenter -- #

# each segment would include:
# id:       timestamp
# duration: cumulative timestamp
# buffers:  array of buffer refs
# header:   computed ID3 header

module.exports = class HLSSegmenter extends require("events").EventEmitter
    constructor: (@rewind,@segment_length,@log) ->
        @segments       = []
        @_segments      = []
        @segment_idx    = {}
        @_rewindLoading = false

        @_min_id        = null

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
                # FIXME: Could this segment ever be anything but the first one
                # if it is in our segments array? Old code suggested yes, but
                # I can't see how. Simplifying until proven wrong.

                if @segments[0] == f_s
                    @segments.shift()
                    delete @segment_idx[f_s.id]
                    @emit "remove", f_s
                    @group?.hlsUpdateMinSegment @segments[0].id

        @rewind.once "_source_waiting", =>
            @_rewindLoading = true

        @rewind.once "_source_init", =>
            @log.debug "HLS sees rewind loaded..."
            @once_queue_settles =>
                @log.debug "HLS rewind loaded and queue settled. Length: #{@segments.length}"
                if @segments[0]
                    @group?.hlsUpdateMinSegment @segments[0].id

                @_rewindLoading = false

        @_gSyncFunc = (id) =>
            @_min_id = id

            # we've received a group minimum segment number. shift off any
            # segments before the id number given
            @log.debug "Segmenter asked to set minimum ID of #{ id }"

            # remove from _segments
            loop
                if (f_s = @_segments[0])? && f_s.id < id
                    @_segments.shift()
                else
                    break

            # remove from segments
            loop
                if (f_s = @segments[0])? && f_s.id < id
                    @segments.shift()
                    delete @segment_idx[ f_s.id ]
                    @emit "remove", f_s
                else
                    break

            @log.debug "First segment id is now #{ @segments[0]?.id } (Length #{ @segments.length })"


    #----------

    syncToGroup: (g) ->
        if @group
            @group = null
            @group.removeListener "hls_update_min_segment", @_gSyncFunc

        @group = g
        @group.addListener "hls_update_min_segment", @_gSyncFunc

        true

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
        @_runQueue() if !@_qRunning

    #----------

    once_queue_settles: (cb) ->
        if @_qRunning
            @once "queue_settled", => cb()
        else
            cb()

    #----------

    _runQueue: ->
        @_qRunning = true

        if @_q.length > 0
            c = @_q.shift()
            @_inject c, => @_runQueue()
        else
            @_qRunning = false
            @emit "queue_settled"

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

            if !seg
                cb()
                return false

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

            if !seg
                cb()
                return false

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

        # don't create a segment we've been told not to have
        if @_min_id && seg_id < @_min_id
            return false

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

        @emit "add", segment

        # if this was our first segment (after rewind load), alert the StreamGroup
        @group?.hlsUpdateMinSegment @segments[0].id if @segments.length == 1 && !@_rewindLoading

        cb()

    #----------

    pumpSegment: (id,cb) ->
        if seg = @segment_idx[ id ]
            cb null, seg
        else
            cb new Error "HTTP Live Streaming segment not found."

    #----------
