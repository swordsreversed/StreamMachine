_ = require "underscore"

module.exports = class HLSSegmenter
    constructor: (@rewind,@segment_length) ->
        @segments       = []
        @_segments      = []
        @segment_idx    = {}

        # The RewindBuffer can get data simultaneously inserted from two
        # directions.  New live data will be emitted as an rpush and will
        # go forward in timestamp.  Loading buffer data will be emitted
        # as an runshift and will go backward in time. We need to listen
        # and construct segments for each.

        @injectFunc = (chunk) =>
            # do we have a segment that this chunk should go into?
            last_seg    = @_segments[ @_segments.length - 1 ]
            first_seg   = @_segments[ 0 ]

            if last_seg && ( last_seg.ts <= chunk.ts < last_seg.end_ts )
                # in our chunk going forward
                last_seg.buffers.push chunk

            else if first_seg && ( first_seg.ts <= chunk.ts < first_seg.end_ts )
                # in our chunk going backward
                first_seg.buffers.unshift chunk

            else if !last_seg || (chunk.ts >= last_seg.end_ts)
                # create a new segment for it
                seg = @_createSegment chunk.ts
                seg.buffers.push chunk

                @_segments.push seg

                # check whether the segment before ours should be finalized
                l = @_segments.length
                @_finalizeSegment @_segments[l-2] if l > 2

            else if chunk.ts < first_seg.ts
                # create a new segment for it
                seg = @_createSegment chunk.ts
                seg.buffers.push chunk

                @_segments.unshift seg

                # check whether the segment after ours should be finalized
                @_finalizeSegment @_segments[1] if @_segments.length > 2

            else
                console.log "Not sure where to place segment!!! ",
                    chunk:chunk
                    first:
                        start:  first_seg.ts
                        end:    first_seg.end_ts
                    last:
                        start:  last_seg.ts
                        end:    last_seg.end_ts

        @rewind.on "rpush",     @injectFunc
        @rewind.on "runshift",  @injectFunc

        @rewind.on "rshift", (chunk) =>
            # Data is being removed from the rewind buffer.  we should
            # clean up our segments as needed

            if (f_s = @_segments[0])? && chunk.ts > f_s.ts
                @_segments.shift()
                if (i = @segments.indexOf(f_s)) > -1
                    @segments.splice(i,1)
                    delete @segment_idx[f_s.id]


    #----------

    _createSegment: (ts) ->
        seg_id = Math.floor( Number(ts) / 1000 / @segment_length )

        id:         seg_id
        ts:         new Date( seg_id * 1000 * @segment_length )
        end_ts:     new Date( seg_id * 1000 * @segment_length + (@segment_length * 1000))
        buffers:    []

    #----------

    _finalizeSegment: (segment) ->
        segment.duration    = _.reduce segment.buffers, ( (d,b) -> d += b.duration ), 0
        segment.data        = Buffer.concat( _(segment.buffers).chain().sortBy("ts").collect((b) -> b.data).value() )
        segment.header      = null

        #segment.buffers.length = 0
        delete segment.buffers

        # add the segment to our finalized list
        if !@segments[0] || segment.ts < @segments[0].ts
            @segments.unshift segment
        else
            @segments.push segment

        # add the segment to our index lookup
        @segment_idx[ segment.id ] = segment

    #----------

    pumpSegment: (id,cb) ->
        if seg = @segment_idx[ id ]
            cb null, seg
        else
            cb new Error "HTTP Live Streaming segment not found."

#----------