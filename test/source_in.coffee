SourceIn    = $src "master/source_in"
Stream      = $src "master/stream"
Logger      = $src "logger"

net = require "net"

debug = require("debug")("sm:tests:source_in")

STREAM =
    key:                "valid"
    source_password:    "abc123"
    seconds:            180
    format:             "mp3"

class FakeMaster
    constructor: (stream) ->
        @streams = {}
        @streams[stream.key] = stream

        @stream_groups = {}

        @log = new Logger stdout:false

describe "Source In", ->
    stream = new Stream null, STREAM.key, (new Logger stdout:false), STREAM
    master = new FakeMaster stream

    it "should listen on a port"

    it "should reject an invalid request", (done) ->
        source_in = new SourceIn core:master, port:0, behind_proxy:false
        source_in.listen()

        source_in.server.once "listening", ->
            debug "Connecting to SourceIn on port #{ source_in.server.address().port }"

            # create a connection
            sock = net.connect port:source_in.server.address().port, ->
                debug "Connected"

                # when we write junk, we expect to just get disconnected. we'll
                # use a timeout to test that.
                t = setTimeout ->
                    done new Error "Socket was not closed after we wrote junk."
                , 1000

                sock.write "JUNK!!!!\r\n\r\n"

                sock.once "close", ->
                    clearTimeout t
                    done()


                #done()


