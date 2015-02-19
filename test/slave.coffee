MasterMode  = $src "modes/master"
SlaveMode   = $src "modes/slave"

StreamListener = $src "util/stream_listener"

master      = null
master_port = null
source_port = null
slave_port  = null

slave       = null

STREAM1 =
    key:                "test1"
    source_password:    "abc123"
    root_route:         true
    seconds:            60*60*4
    format:             "mp3"

mp3 = $file "mp3/mp3-44100-128-s.mp3"

master_config =
    master:
        port:       0
        password:   "zxcasdqwe"
    source_port:    0
    log:
        stdout:     false
    streams:
        test1:      STREAM1

slave_config =
    slave:
        master: "FILLED_IN_BELOW"
    port:       0
    cluster:    2
    log:
        stdout: false

describe "Slave Mode", ->
    before (done) ->
        # unfortunately, to test slave mode, we need a master. that means
        # we get to do a lot here that hopefully gets tested elsewhere

        new MasterMode master_config, (err,m) ->
            throw err if err

            master = m

            master_port = master.handle.address().port
            source_port = master.master.sourcein.server.address().port

            done()

    it "can start up", (done) ->
        this.timeout 10*1000
        slave_config.slave.master = "ws://127.0.0.1:#{master_port}?password=#{master_config.master.password}"
        new SlaveMode slave_config, (err,s) ->
            throw err if err

            slave = s

            slave.once "full_strength", ->
                slave_port = slave._lastAddress.port
                expect(slave_port).to.not.be.undefined
                expect(slave_port).to.be.number
                done()

    it "has the correct number of listening workers", (done) ->
        expect(Object.keys(slave.lWorkers).length).to.eql slave_config.cluster
        done()

    it "has our stream information in all workers", (done) ->
        slave.status (err,status) ->
            throw err if err

            expect(Object.keys(status)).to.have.length 2

            for id,w of status
                expect(w.streams).to.have.key STREAM1.key
                expect(w.streams[ STREAM1.key ].buffer_length).to.eql 0

            done()

    describe "Server", ->
        it "can accept a raw listener", (done) ->
            listener = new StreamListener "127.0.0.1", slave_port, "test1"

            listener.connect (err) =>
                throw err if err
                done()

        it "can accept a Shoutcast listener", (done) ->
            listener = new StreamListener "127.0.0.1", slave_port, "test1", true

            listener.connect (err) =>
                throw err if err
                done()

        it "gives a 404 for a bad stream path", (done) ->
            listener = new StreamListener "127.0.0.1", slave_port, "test2", true

            listener.connect (err) =>
                expect(err).to.not.be.null
                done()
