MasterMode      = $src "modes/master"
Master          = $src "master"
MasterStream    = $src "master/stream"
Logger          = $src "logger"
FileSource      = $src "sources/file"
RewindBuffer    = $src "rewind_buffer"

mp3 = $file "mp3/mp3-44100-64-m.mp3"

nconf   = require "nconf"
_       = require "underscore"

STREAM1 =
    key:                "test1"
    source_password:    "abc123"
    root_route:         true
    seconds:            60*60*4
    format:             "mp3"

describe "Master Stream", ->
    logger = new Logger {}


    describe "Startup", ->
        stream = new MasterStream null, "test1", logger, STREAM1

        it "creates a Rewind Buffer", (done) ->
            expect(stream.rewind).to.be.an.instanceof RewindBuffer
            done()

    #----------

    describe "Multiple Source Connections", ->
        stream = new MasterStream null, "test1", logger, STREAM1

        source  = new FileSource stream, mp3
        source2 = new FileSource stream, mp3

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