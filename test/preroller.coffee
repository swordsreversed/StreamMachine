Preroller   = $src "slave/preroller"
SlaveStream = $src "slave/stream"
Logger      = $src "logger"

mp3 = $file "mp3/tone250Hz-44100-128-m.mp3"

STREAM1 =
    key:                "test1"
    source_password:    "abc123"
    root_route:         true
    seconds:            60*60*4
    format:             "mp3"
    log_minutes:        false
    max_buffer:         2*1024*1024

http = require "http"

describe "Preroller", ->
    logger = new Logger {}

    describe "Setup Scenarios", ->
        stream = null
        before (done) ->
            stream = new SlaveStream {}, "test1", logger, STREAM1
            done()

        it "accepts an HTTP preroller URI", (done) ->
            new Preroller stream, "test1", "http://localhost/test1", (err,pre) ->
                expect(err).to.be.null
                expect(pre).to.be.an.instanceof Preroller
                done()

        it "rejects a non-HTTP preroller URI", (done) ->
            new Preroller stream, "test1", "file:///localhost/test1", (err,pre) ->
                expect(err).to.not.be.null
                expect(pre).to.be.undefined
                done()

    describe "Stream Handling", ->
        stream = null
        before (done) ->
            stream = new SlaveStream {}, "test1", logger, STREAM1
            done()



        it "calls back immediately if it doesn't have a streamKey"

        it "adds the stream key to requests"

    describe "Bad Server", ->

        it "calls back after a timeout if it can't reach preroll server"

    describe "Request Scenarios", ->

        it "pumps the preroll and returns on a normal request"

