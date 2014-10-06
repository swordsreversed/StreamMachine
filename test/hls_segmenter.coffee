RewindBuffer    = $src "rewind_buffer"
HLSSegmenter    = $src "rewind/hls_segmenter"
Logger          = $src "logger"
_ = require "underscore"

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
    beforeEach (done) ->
        rewind = new RewindBuffer liveStreaming:true, seconds:120, burst:30, log:(new Logger {})
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
