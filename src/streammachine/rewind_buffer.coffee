_u          = require 'underscore'
Concentrate = require "concentrate"
Dissolve    = require "dissolve"
nconf       = require "nconf"

Rewinder        = require "./rewind/rewinder"
HLSSegmenter    = require "./rewind/hls_segmenter"

# RewindBuffer supports play from an arbitrary position in the last X hours
# of our stream.

# Buffer is an array of objects. Each object should have:
# * ts:         Timestamp for when chunk was emitted from master stream
# * data:       Chunk of audio data (in either MP3 or AAC)
# * meta:       Metadata that should be running as of this chunk
# * duration:   Duration of the audio chunk

# When the buffer is dumped, it will be in the form of a loop of binary
# packets.  Each will contain:
# * uint8: metadata length
# * Buffer: metadata, stringified into JSON and stuck in a buffer (obj is ts,
#   duration and meta)
# * uint16: data length
# * Buffer: data chunk

# -- HTTP Live Streaming Segmenter -- #

# each segment would include:
# id:       timestamp
# duration: cumulative timestamp
# buffers:  array of buffer refs
# header:   computed ID3 header

module.exports = class RewindBuffer extends require("events").EventEmitter
    constructor: (rewind_opts={}) ->
        @_rsecs         = rewind_opts.seconds || 0
        @_rburstsecs    = rewind_opts.burst || 0
        @_rsecsPerChunk = Infinity
        @_rmax          = null
        @_rburst        = null

        # each listener should be an object that defines obj._offset and
        # obj.writeFrame. We implement RewindBuffer.Listener, but other
        # classes can work with those pieces
        @_rlisteners = []

        # create buffer as an array
        @_rbuffer = []

        # -- set up Live Streaming segments -- #

        if rewind_opts.liveStreaming
            @hls_segmenter = new HLSSegmenter @, nconf.get("live_streaming:segment_duration"), @log

        # -- set up header and frame functions -- #

        @_rdataFunc = (chunk) =>
            # if we're at max length, shift off a chunk (or more, if needed)
            while @_rbuffer.length >= @_rmax
                b = @_rbuffer.shift()
                @emit "rshift", b

            # push the chunk on the buffer
            @_rbuffer.push chunk
            @emit "rpush", chunk

            # loop through all connected listeners and pass the frame buffer at
            # their offset.
            bl = @_rbuffer.length
            for l in @_rlisteners
                # we'll give them whatever is at length - offset
                l._insert @_rbuffer[ bl - 1 - l._offset ]

        # -- look for stream connections -- #

        @on "source", (newsource) =>
            @_rConnectSource newsource

    #----------

    setRewind: (secs,burst) ->
        @_rsecs = secs
        @_rburstsecs = burst
        @_rUpdateMax()

    #----------

    _rConnectSource: (newsource,cb) ->
        @log.debug "RewindBuffer got source event"
        # -- disconnect from old source -- #

        if @_rsource
            @_rsource.removeListener "data", @_rdataFunc
            @log.debug "removed old rewind data listener"

        # -- compute initial stats -- #

        newsource.vitals (err,vitals) =>
            if @_rstreamKey && @_rstreamKey == vitals.streamKey
                # reconnecting, but rate matches so we can keep using
                # our existing buffer.
                @log.debug "Rewind buffer validated new source.  Reusing buffer."

            else
                @_rChunkLength vitals

            # connect our data listener
            newsource.on "data", @_rdataFunc

            # keep track of our source
            @_rsource = newsource

            cb? null

    #----------

    # Return rewind buffer status, including HTTP Live Streaming if enabled
    _rStatus: ->
        status =
            buffer_length:      @_rbuffer.length
            first_buffer_ts:    @_rbuffer[0]?.ts
            last_buffer_ts:     @_rbuffer[ @_rbuffer.length - 1 ]?.ts

        if @hls_segmenter
            _u.extend status, @hls_segmenter.status()

        status

    #----------

    _rChunkLength: (vitals) ->
        if @_rstreamKey != vitals.streamKey
            if @_rstreamKey
                # we're reconnecting, but didn't match rate...  we
                # should wipe out the old buffer
                @log.debug "Invalid existing rewind buffer. Reset."
                @_rbuffer = []

            # compute new frame numbers
            @_rsecsPerChunk = vitals.emitDuration
            @_rstreamKey    = vitals.streamKey

            @_rUpdateMax()

            @log.debug "Rewind's max buffer length is ", max:@_rmax, secsPerChunk:@_rsecsPerChunk, secs:vitals.emitDuration

    #----------

    _rUpdateMax: ->
        if @_rsecsPerChunk
            @_rmax          = Math.round @_rsecs / @_rsecsPerChunk
            @_rburst        = Math.round @_rburstsecs / @_rsecsPerChunk
        @log.debug "Rewind's max buffer length is ", max:@_rmax, seconds:@_rsecs

    #----------

    getRewinder: (id,opts,cb) ->
        # create a rewinder object
        rewind = new Rewinder @, id, opts, cb

        unless opts.pumpOnly
            # add it to our list of listeners
            @_raddListener rewind

    #----------

    bufferedSecs: ->
        # convert buffer length to seconds
        Math.round @_rbuffer.length * @_rsecsPerChunk

    #----------

    # Insert a chunk into the RewindBuffer. Inserts can only go backward, so
    # the timestamp must be less than @_rbuffer[0].ts for a valid chunk
    _insertBuffer: (chunk) ->
        if chunk?.ts < @_rbuffer[0]?.ts||Infinity
            @_rbuffer.unshift chunk
            @emit "runshift", chunk

    #----------

    # Load a RewindBuffer.  Buffer should arrive newest first, which means
    # that we can simply shift() it into place and don't have to lock out
    # any incoming data.

    loadBuffer: (stream,cb) ->
        parser = Dissolve()
            .uint8("header_length")
            .tap ->
                @buffer("header",@vars.header_length)
                    .tap ->
                        @push JSON.parse(@vars.header)
                        @vars = {}

                        @loop (end) ->
                            @uint8("meta_length")
                                .tap ->
                                    @buffer("meta",@vars.meta_length)
                                        .uint16le("data_length")
                                        .tap ->
                                            @buffer("data",@vars.data_length)
                                                .tap ->
                                                    meta = JSON.parse @vars.meta.toString()
                                                    @push ts:new Date(meta.ts), meta:meta.meta, duration:meta.duration, data:@vars.data
                                                    @vars = {}

        stream.pipe(parser)

        headerRead = false

        parser.on "readable", =>
            while c = parser.read()
                if !headerRead
                    headerRead = true

                    @emit "header", c
                    @_rChunkLength emitDuration:c.secs_per_chunk, streamKey:c.stream_key

                else
                    @_insertBuffer(c)
                    @emit "buffer", c

        parser.on "end", =>
            obj = seconds:@bufferedSecs(), length:@_rbuffer.length
            @log.info "RewindBuffer is now at ", obj
            cb? null, obj

    #----------

    # Dump the rewindbuffer. We want to dump the newest data first, so that
    # means running back from the end of the array to the front.

    dumpBuffer: (stream,cb) ->
        # taking a copy of the array should effectively freeze us in place
        rbuf_copy = @_rbuffer.slice(0)

        # make sure there's something to send
        if rbuf_copy.length == 0
            stream.end()
            @log.debug "No rewind buffer to dump."
            cb? null
            return false

        c = Concentrate()

        # Pipe concentrated buffer to the stream object
        c.pipe stream

        slices = 0

        # -- Write header -- #

        header_buf = new Buffer JSON.stringify
            start_ts:       rbuf_copy[0].ts
            end_ts:         rbuf_copy[ rbuf_copy.length - 1 ].ts
            secs_per_chunk: @_rsecsPerChunk
            stream_key:     @_rstreamKey

        # header buffer length
        c.uint8 header_buf.length

        # header buffer json
        c.buffer header_buf

        c.flush()

        # -- Data Chunks -- #

        for i in [(rbuf_copy.length-1)..0]
            chunk = rbuf_copy[ i ]

            meta_buf = new Buffer JSON.stringify ts:chunk.ts, meta:chunk.meta, duration:chunk.duration

            # 1) metadata length
            c.uint8 meta_buf.length

            # 2) metadata json
            c.buffer meta_buf

            # 3) data chunk length
            c.uint16le chunk.data.length

            # 4) data chunk
            c.buffer chunk.data

            c.flush()

            slices += 1

            # clean up
            meta_buf = null

            if i == 0
                c.end()

                rbuf_copy.slice(0)
                rbuf_copy = null

                @log.info "Dumped rewind buffer. Sent #{slices} slices."

                cb? null, slices

        true

    #----------

    checkOffsetSecs: (secs) ->
        @checkOffset @secsToOffset(secs)

    #----------

    checkOffset: (offset) ->
        if offset < 0
            @log.silly "offset is invalid! 0 for live."
            return 0

        if @_rbuffer.length >= offset
            @log.silly "Granted. current buffer length is ", length:@_rbuffer.length
            return offset
        else
            @log.silly "Not available. Instead giving max buffer of ", length:@_rbuffer.length - 1
            return @_rbuffer.length - 1

    #----------

    secsToOffset: (secs) ->
        Math.round Number(secs) / @_rsecsPerChunk

    #----------

    offsetToSecs: (offset) ->
        Math.round Number(offset) * @_rsecsPerChunk

    #----------

    # convert timestamp to an offset number, if the offset exists in our
    # buffer.  If not, return an error
    findTimestamp: (ts,cb) ->
        req_ts      = Number(ts)
        first_ts    = Number( @_rbuffer[0].ts )
        last_ts     = Number( @_rbuffer[ @_rbuffer.length - 1].ts )

        if first_ts <= req_ts <= last_ts
            # it's in there...

            # how many seconds ago?
            secs_ago = Math.ceil( (last_ts - req_ts) / 1000 )
            offset = @secsToOffset secs_ago
            cb null, offset

        else
            cb new Error "Timestamp not found in buffer."

    #----------

    pumpSeconds: (rewinder,seconds,concat,cb) ->
        # pump the most recent X seconds
        frames = @checkOffsetSecs seconds
        @pumpFrom rewinder, frames, frames, concat, cb

    #----------

    pumpFrom: (rewinder,offset,length,concat,cb) ->
        # we want to send _length_ chunks, starting at _offset_

        if offset == 0
            cb? null, null

        # sanity checks...
        if offset > @_rbuffer.length
            offset = @_rbuffer.length

        # can't pump into the future, obviously
        length = offset if length > offset

        bl = @_rbuffer.length

        pumpLen     = 0
        duration    = 0

        meta = null

        buffers = []

        if length > 0
            for i in [1..length]
                b = @_rbuffer[ bl - 1 - (offset - i) ]
                pumpLen     += b.data.length
                duration    += b.duration

                if concat
                  buffers.push b.data
                else
                  rewinder._insert b

                meta = b.meta if !meta

        if concat
          cbuf = Buffer.concat(buffers)
          rewinder._insert { data:cbuf, meta:meta, duration:duration }

        @log.silly "Pumped buffer of ", pumpLen:pumpLen, offset:offset, length:length, bl:bl

        cb? null, meta:meta, duration:duration, length:pumpLen

    #----------

    burstFrom: (rewinder,offset,burstSecs,cb) ->
        # we want to send them @burst frames (if available), starting at offset.
        # return them the new offset position and the burst data

        # convert burstSecs to frames
        burst = @checkOffsetSecs burstSecs

        if offset > burst
            @pumpFrom rewinder, offset, burst, false, (err,info) =>
                cb? err, offset-burst
        else
            @pumpFrom rewinder, offset, offset, false, (err,info) =>
                cb? err, 0

    #----------

    _raddListener: (obj) ->
        if obj._offset? && obj._offset >= 0
            @_rlisteners.push obj
            return true
        else
            return false

    #----------

    _rremoveListener: (obj) ->
        @_rlisteners = _u(@_rlisteners).without obj
        return true

    #----------