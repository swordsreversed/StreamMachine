RewindBuffer    = $src "rewind_buffer"
HLSSegmenter    = $src "rewind/hls_segmenter"
_ = require "underscore"

describe "HTTP Live Streaming Segmenter", ->
    # Wed Apr 16 2014 19:58:04 GMT-0400 (EDT)
    start_ts = 1397692684196

    b_chunks = []
    _(100).times (i) ->
        chunk =
            ts:         new Date(start_ts - i*500)
            duration:   0.5
            data:       new Buffer(0)

        b_chunks.push(chunk)

    f_chunks = []
    _(100).times (i) ->
        chunk =
            ts:         new Date(start_ts + i*500)
            duration:   0.5
            data:       new Buffer(0)

        f_chunks.push(chunk)

    # pop the first one to avoid duplication
    f_chunks.splice(0,1)

    rewind      = null
    beforeEach (done) ->
        rewind = new RewindBuffer liveStreaming:true
        done()

    it "creates the Live Streaming Segmenter", (done) ->
        expect(rewind.hls_segmenter).to.be.an.object
        expect(rewind.hls_segmenter).to.be.an.instanceof(HLSSegmenter)
        done()

    it "correctly segments forward-facing data", (done) ->
        # we'll inject 100 chunks of fake 0.5 second audio data

        for c in f_chunks
            rewind._rdataFunc c

        # 50 seconds of audio data should have produced four HLS segments
        # (four whole ones, plus some change)

        #console.log "segments is ", rewind.hls_segmenter._segments
        expect(rewind.hls_segmenter._segments).to.have.length 6
        expect(rewind.hls_segmenter.segments()).to.have.length 4

        for seg in rewind.hls_segmenter._segments
            if seg.buffer
                expect(seg.duration).to.be.equal 10
            else
                expect(seg.buffers).to.have.length.below 20

        first_seg = rewind.hls_segmenter._segments[0]
        # there are 11 half-seconds between our start time and the next segment
        expect(first_seg.buffers).to.have.length 11
        expect(first_seg.duration).to.be.undefined

        done()


    it "correctly segments injected buffer data", (done) ->
        for c in b_chunks
            rewind._insertBuffer c

        expect(rewind.hls_segmenter._segments).to.have.length 6
        expect(rewind.hls_segmenter.segments()).to.have.length 4

        for seg in rewind.hls_segmenter._segments
            if seg.buffer
                expect(seg.duration).to.be.equal 10
            else
                expect(seg.buffers).to.have.length.below 20

        done()

    it "correctly segments mixed data", (done) ->
        _(f_chunks).each (c) -> rewind._rdataFunc c
        _(b_chunks).each (c) -> rewind._insertBuffer c

        expect(rewind.hls_segmenter._segments).to.have.length 11

        for seg in rewind.hls_segmenter._segments
            if seg.buffer
                expect(seg.duration).to.be.equal 10
            else
                expect(seg.buffers).to.have.length.below 20

        done()