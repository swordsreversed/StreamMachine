RewindBuffer    = $src "rewind_buffer"
HLSSegmenter    = $src "rewind/hls_segmenter"
Logger          = $src "logger"
_ = require "underscore"

#----------

class FakeStreamGroup extends require("events").EventEmitter
    constructor: (rewinds) ->
        @updates = []
        @hls_min_id = null

        for r in rewinds
            r.hls_segmenter.syncToGroup @

    hlsUpdateMinSegment: (id) ->
        @updates.push id
        if !@hls_min_id || id > @hls_min_id
            prev = @hls_min_id
            @hls_min_id = id
            @emit "hls_update_min_segment", id

#----------

describe "HTTP Live Streaming Segmenter", ->
    # Wed Apr 16 2014 19:58:04 GMT-0400 (EDT)
    start_ts = 1397692684196

    b_chunks = []
    _(120).times (i) ->
        chunk =
            ts:         new Date(start_ts - i*500)
            duration:   0.5
            data:       new Buffer(0)

        b_chunks.push(chunk)

    f_chunks = []
    _(121).times (i) ->
        chunk =
            ts:         new Date(start_ts + i*500)
            duration:   0.5
            data:       new Buffer(0)

        f_chunks.push(chunk)

    # pop the first one to avoid duplication
    f_chunks.splice(0,1)

    rewind      = null

    describe "Standalone", ->
        beforeEach (done) ->
            # Set up rewind buffer with HLS enabled using 10-second chunks
            rewind = new RewindBuffer hls:10, seconds:120, burst:30, log:(new Logger {})
            rewind._rChunkLength emitDuration:0.5, streamKey:"testing"
            done()

        it "creates the Live Streaming Segmenter", (done) ->
            expect(rewind.hls_segmenter).to.be.an.object
            expect(rewind.hls_segmenter).to.be.an.instanceof(HLSSegmenter)
            done()

        it "segments forward-facing data", (done) ->
            # we'll inject 100 chunks of fake 0.5 second audio data

            for c in f_chunks
                rewind._insertBuffer c

            # 50 seconds of audio data should have produced four HLS segments
            # (four whole ones, plus some change)

            #console.log "segments is ", rewind.hls_segmenter._segments
            expect(rewind.hls_segmenter._segments).to.have.length 7
            expect(rewind.hls_segmenter.segments).to.have.length 5

            for seg in rewind.hls_segmenter._segments
                if seg.data
                    expect(seg.duration).to.be.equal 10
                else
                    expect(seg.buffers).to.have.length.below 20

            first_seg = rewind.hls_segmenter._segments[0]
            # there are 11 half-seconds between our start time and the next segment
            expect(first_seg.buffers).to.have.length 11
            expect(first_seg.duration).to.be.undefined

            done()


        it "segments injected buffer data", (done) ->
            for c in b_chunks
                rewind._insertBuffer c

            expect(rewind.hls_segmenter._segments).to.have.length 7
            expect(rewind.hls_segmenter.segments).to.have.length 5

            for seg in rewind.hls_segmenter._segments
                if seg.data
                    expect(seg.duration).to.be.equal 10
                else
                    expect(seg.buffers).to.have.length.below 20

            done()

        it "segments mixed data", (done) ->
            _(f_chunks).each (c) -> rewind._insertBuffer c
            _(b_chunks).each (c) -> rewind._insertBuffer c

            expect(rewind.hls_segmenter._segments).to.have.length 13

            for seg in rewind.hls_segmenter._segments
                if seg.data
                    expect(seg.duration).to.be.equal 10
                else
                    expect(seg.buffers).to.have.length.below 20

            done()

        it "removes segments as needed", (done) ->
            rewind.setRewind(30,30)

            for c in f_chunks
                rewind._rdataFunc c

            expect(rewind._rbuffer.length()).to.be.equal 60
            expect(rewind.hls_segmenter.segments).to.have.length 2
            expect(rewind.hls_segmenter._segments).to.have.length 3
            expect(Object.keys(rewind.hls_segmenter.segment_idx)).to.have.length 2
            done()

    describe "Stream Group Coordination", ->
        r1 = null
        r2 = null
        sg = null

        before (done) ->
            r1 = new RewindBuffer hls:10, seconds:120, burst:30, log:(new Logger {})
            r1._rChunkLength emitDuration:0.5, streamKey:"testing"

            r2 = new RewindBuffer hls:10, seconds:120, burst:30, log:(new Logger {})
            r2._rChunkLength emitDuration:0.5, streamKey:"testing"

            sg = new FakeStreamGroup [r1,r2]

            done()

        it "should trigger updates to stream group min segment ID", (done) ->
            # stream all f_chunks into r1, but skip some for r2
            for c,i in f_chunks
                r1._insertBuffer c
                r2._insertBuffer c if i > 25

            expect(sg.updates.length).to.eql 2
            done()

        it "both RewindBuffers should have the correct first segment", (done) ->
            expect(r1._rStatus().hls_first_seg_id).to.eql sg.hls_min_id
            expect(r2._rStatus().hls_first_seg_id).to.eql sg.hls_min_id
            done()

        it "should stay correct when data is expired unevenly", (done) ->
            r1.setRewind(30,30)

            expect(sg.updates.length).to.eql 4
            expect(r1._rStatus().hls_first_seg_id).to.eql sg.hls_min_id
            expect(r2._rStatus().hls_first_seg_id).to.eql sg.hls_min_id
            done()
