RewindBuffer    = $src "rewind_buffer"
HLSSegmenter    = $src "rewind/hls_segmenter"
Logger          = $src "logger"

ChunkGenerator  = $src "util/chunk_generator"

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
    rewind      = null

    chunk_duration      = 1000
    segment_duration    = 10000

    start_ts = new Date(1415290170623)
    #start_ts = new Date()

    # If our start_ts falls exactly on a segment start, we need to give a bump
    # to expected segment counts where we're going backward and forward

    seg_bonus = 0
    start_sec = Math.floor( Number(start_ts) / 1000 ) * 1000
    if Math.floor( start_sec / segment_duration ) * segment_duration == start_sec
        seg_bonus = 1

    console.log "Start ts is ", start_ts, seg_bonus

    #----------

    # The chunk injector takes a stream of audio chunks going forward and/or
    # backward from a common starting point, emitting segments each time a
    # segment length boundary is crossed. These semi-baked segments will have
    # start and end timestamps and a `buffers` array that contains the matching
    # chunks. It will reject pushes that aren't at the edges of the segment list.

    describe "Chunk Injector", ->
        injector    = null
        generator   = null

        beforeEach (done) ->
            injector = new HLSSegmenter.Injector segment_duration, (new Logger {})
            generator = new ChunkGenerator start_ts, chunk_duration
            generator.pipe(injector)
            done()

        afterEach (done) ->
            generator.unpipe()
            injector.removeAllListeners()
            done()

        it "accepts forward chunks and produces segments", (done) ->
            segments = []
            injector.on "readable", ->
                while s = injector.read()
                    segments.push s

            injector.once "finish", ->
                expect(segments.length).to.eql 3
                expect( Number(segments[1].ts) - Number(segments[0].ts) ).to.eql segment_duration

                done()

            # producing 31 seconds of audio should give us 3 pushed segments
            generator.forward 31, ->
                generator.end()

        it "doesn't emit a segment if not given enough data", (done) ->
            injector.once "segment", ->
                throw new Error "No segment was supposed to be created."

            injector.once "finish", ->
                done()

            # since we emit when _segments.length > 2, 19 seconds can't produce
            # an emitted segment
            generator.forward 19, -> generator.end()

        it "emits segments when given backward data", (done) ->
            segments = []
            injector.on "readable", ->
                while s = injector.read()
                    segments.push s

            injector.once "finish", ->
                expect(segments.length).to.eql 3
                expect( Number(segments[0].ts) - Number(segments[1].ts) ).to.eql segment_duration

                done()

            generator.backward 31, ->
                generator.end()

        it "emits mixed segments when given mixed data", (done) ->
            expected_segs = 5 + seg_bonus

            segments = []
            injector.on "readable", ->
                while s = injector.read()
                    segments.push s

            injector.once "finish", ->
                expect(segments.length).to.eql expected_segs

                # sort by ts
                segments = _(segments).sortBy (s) -> Number(s.ts)

                # five segments should cover 40 seconds going by timestamp
                expect( Number(segments[4].ts) - Number(segments[0].ts) ).to.eql 4 * segment_duration

                done()

            af = _.after 2, -> generator.end()

            generator.forward 30, -> af()
            generator.backward 30, -> af()

    #----------

    # The Finalizer sits after the Injector. It takes the half-baked segments
    # that the Injector emits and gives them sequence IDs. These can be from a
    # loaded sequence map (to reload data on startup, for instance), or they
    # can be generated sequence numbers going forward. The Finalizer is also
    # in charge of spotting gaps in the segment array, inserting discontinuity
    # objects where appropriate and keeping track of the discontinuity sequence.

    describe "Segment Finalizer", ->
        generator   = null
        injector    = null
        beforeEach (done) ->
            injector = new HLSSegmenter.Injector segment_duration, (new Logger {})
            generator = new ChunkGenerator start_ts, chunk_duration
            generator.pipe(injector)
            done()

        afterEach (done) ->
            generator.unpipe()
            injector.unpipe()
            done()

        it "assigns sequenced IDs to new segments", (done) ->
            finalizer = new HLSSegmenter.Finalizer (new Logger {})
            injector.pipe(finalizer)

            finalizer.on "finish", ->
                expect( finalizer.segmentSeq ).to.eql 2
                expect( finalizer.discontinuitySeq ).to.eql 0
                expect( finalizer.segments ).to.have.length 2
                expect( finalizer.segments[0].id ).to.eql 0
                expect( finalizer.segments[1].id ).to.eql 1
                done()

            generator.forward 31, -> generator.end()

        it "creates a discontinuity when given a gap", (done) ->
            # if our start aligned, we don't get the truncated segment that
            # would have otherwise been emitted
            expected_seq = 3 - seg_bonus

            finalizer = new HLSSegmenter.Finalizer (new Logger {})
            injector.pipe(finalizer)

            finalizer.on "finish", ->
                expect( finalizer.segmentSeq ).to.eql expected_seq
                expect( finalizer.discontinuitySeq ).to.eql 1

                expect( finalizer.segments[ 0 ].discontinuitySeq ).to.eql 0
                expect( finalizer.segments[ finalizer.segments.length - 1 ].discontinuitySeq ).to.eql 1

                done()

            generator.forward 20, -> generator.skip_forward 10, ->
                generator.forward 10, -> generator.end()

        it "will use a segment map to assign sequence numbers", (done) ->
            f_seg = injector._createSegment start_ts

            seq = 5
            seg_map = {}
            for i in [0..2]
                seg_map[ Number(f_seg.ts) + i*segment_duration ] = seq
                seq += 1

            finalizer = new HLSSegmenter.Finalizer (new Logger {}),
                segmentSeq:         8
                nextSegment:        f_seg.ts
                discontinuitySeq:   0
                segmentMap:         seg_map

            injector.pipe(finalizer)

            finalizer.on "finish", ->
                expect(finalizer.segments).to.have.length 4
                expect(finalizer.segments[0].id).to.eql 5
                expect(finalizer.segments[1].id).to.eql 6
                expect(finalizer.segments[2].id).to.eql 7
                expect(finalizer.segments[3].id).to.eql 8

                done()

            generator.forward 40, -> generator.end()

        it "will use a segment map to assign sequence numbers to back data", (done) ->
            f_seg = injector._createSegment start_ts

            seq = 5
            seg_map = {}
            for i in [3..1]
                seg_map[ Number(f_seg.ts) - i*segment_duration ] = seq
                seq += 1

            finalizer = new HLSSegmenter.Finalizer (new Logger {}),
                segmentSeq:         8
                nextSegment:        f_seg.ts
                discontinuitySeq:   0
                segmentMap:         seg_map

            injector.pipe(finalizer)

            finalizer.on "finish", ->
                expect(finalizer.segments).to.have.length 4

                for seg in finalizer.segments
                    if Number(seg.ts) == start_sec
                        expect(seg.id).to.eql 8
                    else
                        map_id = seg_map[ Number( seg.ts ) ]
                        expect(map_id).to.not.be.undefined
                        expect(seg.id).to.eql map_id

                done()

            af = _.after 2, ->
                generator.end()

            generator.forward 10, af
            generator.backward 30, af

        it "will not publish a segment that is not in the segment map", (done) ->
            f_seg = injector._createSegment start_ts

            seq = 5
            seg_map = {}
            for i in [3..1]
                seg_map[ Number(f_seg.ts) - i*segment_duration ] = seq
                seq += 1

            for m in [[1,7],[3,6]]
                seg_map[ Number(f_seg.ts) - m[0]*segment_duration ] = m[1]

            finalizer = new HLSSegmenter.Finalizer (new Logger {}),
                segmentSeq:         8
                nextSegment:        f_seg.ts
                discontinuitySeq:   0
                segmentMap:         seg_map

            injector.pipe(finalizer)

            finalizer.on "finish", ->
                expect(finalizer.segments).to.have.length 3

                for seg in finalizer.segments
                    map_id = seg_map[ Number( seg.ts ) ]
                    expect(map_id).to.not.be.undefined
                    expect(seg.id).to.eql map_id

                done()

            generator.backward 40, -> generator.end()

        it "will correctly number discontinuities in back data", (done) ->
            f_seg = injector._createSegment start_ts

            seg_map = {}
            for m in [[1,7],[2,6],[4,5]]
                seg_map[ Number(f_seg.ts) - m[0]*segment_duration ] = m[1]

            finalizer = new HLSSegmenter.Finalizer (new Logger {}),
                segmentSeq:         8
                nextSegment:        f_seg.ts
                discontinuitySeq:   4
                segmentMap:         seg_map

            injector.pipe(finalizer)

            finalizer.on "finish", ->
                expect(finalizer.segments).to.have.length 3
                expect(finalizer.segments[0].discontinuitySeq).to.eql 3

                done()

            generator.backward 20, -> generator.skip_backward 10,
                -> generator.backward 10, -> generator.end()

        it "can dump map info", (done) ->

            finalizer = new HLSSegmenter.Finalizer (new Logger {})
            injector.pipe(finalizer)

            finalizer.on "finish", ->
                finalizer.dumpMap (err,map) ->
                    expect( map ).to.have.property "segmentMap"
                    expect( map ).to.have.property "segmentSeq"
                    expect( map ).to.have.property "discontinuitySeq"
                    expect( map ).to.have.property "nextSegment"
                    done()

            generator.forward 41, -> generator.end()

        it "can dump a snapshot", (done) ->
            finalizer = new HLSSegmenter.Finalizer (new Logger {})
            injector.pipe(finalizer)

            finalizer.on "finish", ->
                finalizer.snapshot (err,snapshot) ->
                    expect( snapshot ).to.be.instanceof Array
                    expect( snapshot ).to.have.length 3

                    for s,i in snapshot
                        expect(s.discontinuitySeq).to.eql 0
                        expect(s.id).to.eql i

                    done()

            generator.forward 41, -> generator.end()


    #----------

    return false

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
