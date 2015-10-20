Preroller   = $src "slave/preroller"
SlaveStream = $src "slave/stream"
Logger      = $src "logger"

AdServer    = $src "util/fake_ad_server"
Transcoder  = $src "util/fake_transcoder"

fs = require "fs"
debug = require("debug")("sm:tests:preroller")

mp3 = $file "mp3/tone250Hz-44100-128-m.mp3"

STREAM1 =
    key:                "test1"
    source_password:    "abc123"
    root_route:         true
    seconds:            60*60*4
    format:             "mp3"
    log_minutes:        false
    max_buffer:         2*1024*1024

CLIENT =
    ip:         "127.0.0.1"
    ua:         "SCPRWEB | Mozilla/5.0 (Macintosh; Intel Mac OS X 10.6; rv:39.0) Gecko/20100101 Firefox/39.0"
    session_id: 1234

class FakeStream
    constructor: (@key) ->
        @log = new Logger {}

    getStreamKey: (cb) ->
        cb @key

class WriteCollector extends require("stream").Writable
    constructor: ->
        @length = 0
        super()

    _write: (chunk,encoding,cb) ->
        @length += chunk.length
        @emit "write"
        cb()

    onceWritten: (cb) ->
        if @length > 0
            cb()
        else
            @once "write", cb


describe "Preroller", ->
    logger = new Logger {}

    describe "XML Ad Formats", ->
        doc = ""

        before (done) ->
            debug "Loading VAST doc"
            s = fs.createReadStream $file "ads/vast.xml"
            s.on "readable", ->
                doc += r while r = s.read()

            s.once "end", ->
                debug "VAST XML loaded. Length is #{doc.length}."
                done()

        it "Parses VAST ad", (done) ->
            new Preroller.AdObject doc, (err,obj) ->
                throw err if err

                expect(obj.creativeURL).to.eql "AUDIO"
                expect(obj.impressionURL).to.eql "IMPRESSION"
                done()

    describe "Preroll Scenarios", ->
        adserver = null
        transcoder = null
        
        impression_cb = null

        before (done) ->
            debug "Setting up fake services"

            transcoder = new Transcoder 0, $file "mp3/"
            debug "Transcoder is listening on port #{transcoder.port}"

            adserver = new AdServer 0, $file("ads/vast.xml"), =>
                debug "Ad server is listening on port #{adserver.port}"
                done()

        it "pumps data when preroll is active", (done) ->
            stream = new FakeStream "mp3-44100-128-s"
            new Preroller stream,
                "test",
                "http://127.0.0.1:#{adserver.port}/ad",
                "http://127.0.0.1:#{transcoder.port}/encoding",
                (err,preroller) =>
                    debug "Preroller init"

                    writer = new WriteCollector()

                    preroller.pump CLIENT, writer, writer, (err,icb) ->
                        throw err if err
                        
                        impression_cb = icb

                        writer.onceWritten ->
                            debug "writer got bytes"
                            done()
                            
        it "hits impression URL when callback is triggered", (done) ->
            adserver.once "impression", (req_id) ->
                debug "Got impression from req_id #{req_id}"
                done()
                
            expect(impression_cb).to.be.function
            
            impression_cb()





