MasterMode      = $src "modes/master"
Master          = $src "master"
MasterStream    = $src "master/stream"
Logger          = $src "logger"
FileSource      = $src "sources/file"
RewindBuffer    = $src "rewind_buffer"
HLSSegmenter    = $src "rewind/hls_segmenter"

mp3 = $file "mp3/mp3-44100-64-m.mp3"

_       = require "underscore"

#process.exit()

STREAM1 =
    key:                "test1"
    source_password:    "abc123"
    root_route:         true
    seconds:            60*60*4
    format:             "mp3"

describe "Master Stream", ->
    logger = new Logger stdout:false


    describe "Startup", ->
        stream = new MasterStream null, "test1", logger, STREAM1

        it "creates a Rewind Buffer", (done) ->
            expect(stream.rewind).to.be.an.instanceof RewindBuffer
            done()

    #----------

    describe "Typical Source Connections", ->
        stream = new MasterStream null, "test1", logger, STREAM1

        source  = new FileSource format:"mp3", filePath:mp3, chunkDuration:0.1
        source2 = new FileSource format:"mp3", filePath:mp3, chunkDuration:0.1

        it "activates the first source to connect", (done) ->
            expect(stream.source).to.be.null

            stream.addSource source, (err) ->
                throw err if err
                expect(stream.source).to.equal source
                done()

        it "queues the second source to connect", (done) ->
            expect(stream.sources).to.have.length 1

            stream.addSource source2, (err) ->
                throw err if err
                expect(stream.sources).to.have.length 2
                expect(stream.source).to.equal source
                expect(stream.sources[1]).to.equal source2
                done()

        it "promotes an alternative source when requested", (done) ->
            expect(stream.source).to.equal source

            stream.promoteSource source2.uuid, (err) ->
                throw err if err
                expect(stream.source).to.equal source2

                stream.promoteSource source.uuid, (err) ->
                    throw err if err
                    expect(stream.source).to.equal source
                    done()

        it "switches to the second source if the first disconnects", (done) ->
            stream.once "source", (s) ->
                expect(s).to.equal source2
                done()

            source.disconnect()

    describe "Source Connection Scenarios", ->
        mp3a = $file "mp3/tone250Hz-44100-128-m.mp3"
        mp3b = $file "mp3/tone440Hz-44100-128-m.mp3"
        mp3c = $file "mp3/tone1kHz-44100-128-m.mp3"

        stream  = null
        source1 = null
        source2 = null
        source3 = null

        beforeEach (done) ->
            stream = new MasterStream null, "test1", logger, STREAM1
            source1 = new FileSource format:"mp3", filePath:mp3a, chunkDuration:0.1
            source2 = new FileSource format:"mp3", filePath:mp3b, chunkDuration:0.1
            source3 = new FileSource format:"mp3", filePath:mp3c, chunkDuration:0.1
            done()

        afterEach (done) ->
            stream.removeAllListeners()
            source1.removeAllListeners()
            source2.removeAllListeners()
            source3.removeAllListeners()
            done()

        it "doesn't get confused by simultaneous addSource calls", (done) ->
            stream.once "source", ->
                # listen for five data emits.  they should all come from
                # the same source uuid
                emits = []

                af = _.after 5, ->
                    uuid = stream.source.uuid

                    expect(emits[0].uuid).to.equal uuid
                    expect(emits[1].uuid).to.equal uuid
                    expect(emits[2].uuid).to.equal uuid
                    expect(emits[3].uuid).to.equal uuid
                    expect(emits[4].uuid).to.equal uuid

                    done()

                stream.on "data", (data) ->
                    emits.push data
                    af()

            stream.addSource source1
            stream.addSource source2

            source1.start()
            source2.start()

        it "doesn't get confused by quick promoteSource calls", (done) ->
            stream.addSource source1, ->
                stream.addSource source2, ->
                    stream.addSource source3, ->
                        source1.start()
                        source2.start()
                        source3.start()

                        # listen for five data emits.  they should all come from
                        # the same source uuid
                        emits = []

                        af = _.after 5, ->
                            uuid = stream.source.uuid

                            expect(emits[0].uuid).to.equal uuid
                            expect(emits[1].uuid).to.equal uuid
                            expect(emits[2].uuid).to.equal uuid
                            expect(emits[3].uuid).to.equal uuid
                            expect(emits[4].uuid).to.equal uuid

                            done()

                        stream.on "data", (data) ->
                            emits.push data
                            af()

                        stream.promoteSource source2.uuid
                        stream.promoteSource source3.uuid

    describe "HLS", ->
        stream = null
        source = null
        before (done) ->
            stream  = new MasterStream null, "test1", logger, _.extend {}, STREAM1, hls:{segment_duration:10}
            source  = new FileSource format:"mp3", filePath:mp3, chunkDuration:0.5
            stream.addSource source

            source.once "_loaded", ->
                # emit 49 seconds of data
                start_ts = Number(new Date())
                for i in [0..98]
                    source._emitOnce new Date( start_ts + i*500 )

                done()

        it "should have created an HLS Segmenter", (done) ->
            expect( stream.rewind.hls_segmenter ).to.be.instanceof HLSSegmenter
            done()

        it "should have loaded data into the RewindBuffer", (done) ->
            expect( stream.rewind._rbuffer.length() ).to.be.gt 1
            done()

        it "should have created HLS segments", (done) ->
            this.timeout 5000
            stream.rewind.hls_segmenter.once "snapshot", (snapshot) =>
                expect(snapshot.segments).to.have.length 4
                expect(snapshot.segment_duration).to.eq 10
                done()
