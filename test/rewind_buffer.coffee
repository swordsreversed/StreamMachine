RewindBuffer    = $src "rewind_buffer"
FileSource      = $src "sources/file"
Logger          = $src "logger"

mp3_a = $file "mp3/mp3-44100-64-s.mp3"
mp3_b = $file "mp3/mp3-44100-128-s.mp3"

describe "Rewind Buffer", ->
    rewind      = null
    source_a    = null
    source_b    = null

    logger = new Logger {}

    before (done) ->
        rewind = new RewindBuffer

        # fake options that would have been on our stream class
        rewind.opts =
            seconds:    60
            burst:      30

        rewind.log = logger

        done()

    before (done) ->
        source_a = new FileSource format:"mp3", filePath:mp3_a, do_not_emit:true
        source_b = new FileSource format:"mp3", filePath:mp3_b, do_not_emit:true
        done()

    it "starts with a bufferedSecs of NaN", (done) ->
        expect( rewind.bufferedSecs() ).to.eql NaN
        done()

    describe "on source...", ->
        it "accepts a source", (done) ->
            rewind._rConnectSource source_a, ->
                expect(rewind._rsource).to.eql source_a
                done()

        it "reads emit duration", (done) ->
            expect(rewind._rsecsPerChunk).to.eql source_a.emitDuration
            done()

        it "sets streamKey", (done) ->
            expect(rewind._rstreamKey).to.eql source_a.streamKey
            done()

    describe "on data...", ->
        events = rshift:0, rpush:0
        before (done) ->
            rewind.on "rshift", (b) -> events.rshift += 1
            rewind.on "rpush", (b) -> events.rpush += 1

            # now emit one chunk...
            source_a._emitOnce()

            done()

        it "pushes one data chunk", (done) ->
            expect(events.rpush).to.eql 1
            done()

        it "gives the right buffered duration", (done) ->
            # the value is allowed to be rounded
            expect( rewind.bufferedSecs() ).to.be.within Math.floor(source_a.emitDuration), Math.ceil(source_a.emitDuration)
            done()

        describe "on much data...", ->
            ts = Number(new Date)
            before (done) ->
                # push two minutes of data (240 samples)
                for i in [0..239]
                    c_ts = new Date(ts+source_a.emitDuration*1000*i)
                    source_a._emitOnce(c_ts)

                done()

            it "pushed 241 data chunks", (done) ->
                expect(events.rpush).to.eql 241
                done()

            it "shifted off 121 data chunks", (done) ->
                expect(events.rshift).to.eql 121
                done()

            it "still knows buffered duration", (done) ->
                # the value is allowed to be rounded
                dur = 125 * source_a.emitDuration
                expect( rewind.bufferedSecs() ).to.be.within rewind.opts.seconds, rewind.opts.seconds + 1
                done()

            it "can find a timestamp inside the buffer", (done) ->
                f_ts = new Date(ts+1*60*1000)
                rewind.findTimestamp f_ts, (err,offset) ->
                    expect(err).to.be.null
                    # should be the "last" timestamp in the buffer... first on the array
                    expect(offset).to.eql 120
                    done()

            it "errors if a timestamp isn't in the buffer", (done) ->
                f_ts = new Date(ts+2*60*1000)
                rewind.findTimestamp f_ts, (err,offset) ->
                    expect(err).to.be.instanceof Error
                    done()



