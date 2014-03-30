FileSource      = $src "sources/file"
MasterStream    = $src "master/stream"
Logger          = $src "logger"

STREAM1 =
    key:                "test1"
    source_password:    "abc123"
    root_route:         true
    seconds:            60*60*4
    format:             "mp3"

mp3 = $file "mp3/mp3-44100-64-s.mp3"

describe "File Source", ->
    logger = new Logger {}
    stream = new MasterStream null, "test1", logger, STREAM1
    source = new FileSource stream, mp3

    before (done) ->
        stream.addSource source, done

    it "should set the correct streamKey", (done) ->
        stream.getStreamKey (key) ->
            expect(key).to.equal "mp3-44100-64-s"
            done()

    it "should emit data", (done) ->
        stream.once "data", (data) ->
            expect(data).to.be.an.object
            expect(data.duration).to.be.a.number
            expect(data.data).to.be.an.instanceof Buffer
            done()