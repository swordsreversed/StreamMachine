MasterMode      = $src "modes/master"
Master          = $src "master"
MasterStream    = $src "master/stream"

SlaveIO         = $src "slave/slave_io"
Logger          = $src "logger"

nconf   = require "nconf"
_       = require "underscore"

STREAM1 =
    key:                "test1"
    source_password:    "abc123"
    root_route:         true
    seconds:            60*60*4
    format:             "mp3"

class FakeSlave extends require("events").EventEmitter
    constructor: ->
        @streams = null

    configureStreams: (s) ->
        @streams = s
        @emit "config"

    onceConfigured: (cb) ->
        if @streams
            cb()
        else
            @once "config", cb

describe "StreamMachine Master Mode", ->
    mm = null

    port_master = null
    port_source = null

    # -- Initialize our master -- #

    before (done) ->
        settings = nconf.get()
        delete settings.redis
        delete settings.analytics

        new MasterMode settings, (err,m) =>
            return throw err if err

            mm = m

            port_master = mm.handle?.address().port
            port_source = mm.master.sourcein?.server?.address().port

            done()

    after (done) ->
        mm.master.monitoring.shutdown()
        done()

    # -- Test our startup state -- #

    describe "Startup", ->
        it "should have started a Master instance", (done) ->
            expect(mm.master).to.be.a.instanceof(Master)
            done()

        it "should be listening on a source port", (done) ->
            expect(port_source).not.to.be.undefined
            done()

        it "should be listening on an admin port", (done) ->
            expect(port_master).not.to.be.undefined
            done()

        it "should have no streams configured", (done) ->
            expect(mm.master.streams).to.be.empty
            done()

        it "should have no slaves", (done) ->
            expect(mm.master.slaves.slaves).to.be.empty
            done()

        it "should be listening for slaves"

    # -- Configure a Stream -- #

    describe "Stream Configuration", ->
        streams_emitted = false
        before (done) ->
            mm.master.once "streams", -> streams_emitted = true
            done()

        it "should accept a new stream", (done) ->
            c = streams:{}, sources:{}
            c.streams[ STREAM1.key ] = STREAM1

            mm.master.configure c, (err,config) ->
                expect(err).to.be.null
                expect(config).to.have.property 'streams'
                expect(config.streams).to.have.property STREAM1.key
                expect(config.streams?[STREAM1.key]).to.be.an.instanceof MasterStream
                done()

        it "should have emitted 'streams' when configured", (done) ->
            expect(streams_emitted).to.be.true
            done()

    # -- Slaves -- #

    describe "Slave Connections", ->
        s_log   = new Logger stdout:false
        slave   = null
        s_io    = null

        it "should allow a slave connection", (done) ->
            slave   = new FakeSlave
            s_io    = new SlaveIO slave, s_log, master:"ws://localhost:#{port_master}?password=#{nconf.get("master:password")}"

            err_f = (err) -> throw err

            s_io.once "error", err_f

            s_io.once_connected (err,io) ->
                throw err if err
                s_io.removeListener "error", err_f

                expect(io.connected).to.be.true
                expect(s_io.connected).to.be.true

                done()

        it "should emit configuration to the slave", (done) ->
            # it's possible (and fine) to not get config immediately if the master
            # hasn't finished its config
            slave.onceConfigured ->
                expect(slave.streams).to.be.object
                expect(slave.streams).to.have.property STREAM1.key
                done()

        it "should deny a slave that provides the wrong password"


    # -- Sources -- #

    describe "Source Connections", ->

        it "should accept a source connection"

        it "should deny a source connection with the wrong password"

    # -- Source -> Stream -- #

    describe "Source -> Stream", ->
        # TODO: before to connect a source and pipe in an mp3 file

        it "should add the new source to our stream"

        it "should have set the stream's stream key"

        it "should start emitting data"