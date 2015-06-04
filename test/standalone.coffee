StandaloneHelper    = require "./helpers/standalone"

StreamListener  = $src "util/stream_listener"
IcecastSource   = $src "util/icecast_source"

mp3 = $file "mp3/mp3-44100-128-s.mp3"

debug = require("debug")("sm:tests:standalone")
request = require "request"

describe "Standalone Mode", ->
    sa_info     = null
    standalone  = null

    before (done) ->
        StandaloneHelper.startStandalone 'mp3', (err,info) ->
            throw err if err

            sa_info = info
            standalone = info.standalone

            done()

    it "should map slave stream sources to master streams", (done) ->
        standalone.master.once_configured ->
            expect(standalone.master.streams).to.have.key sa_info.stream_key
            expect(standalone.slave.streams).to.have.key sa_info.stream_key

            expect(standalone.slave.streams[sa_info.stream_key].source).to.eql standalone.master.streams[sa_info.stream_key]

            done()

    it "should accept a source", (done) ->
        source = new IcecastSource
            format:     "mp3"
            filePath:   mp3
            host:       "127.0.0.1"
            port:       sa_info.source_port
            password:   sa_info.source_password
            stream:     sa_info.stream_key

        source.start (err) ->
            throw err if err

            status = standalone.master.streams[sa_info.stream_key].status()
            expect(status.sources).to.have.length 1
            done()

    it "should accept a listener and feed it data", (done) ->
        this.timeout 4000
        listener = new StreamListener "127.0.0.1", sa_info.port, sa_info.stream_key

        listener.connect (err) =>
            throw err if err

            listener.once "bytes", ->
                listener.disconnect()
                done()

    it "should accept an API call to /streams", (done) ->
        request.get url:"#{sa_info.api_uri}/streams", json:true, (err,res,json) ->
            throw err if err

            expect(res.statusCode).to.be.eql 200
            expect(json).to.be.instanceof Array
            expect(json).to.have.length 1
            expect(json[0].key).to.eql sa_info.stream_key

            done()
