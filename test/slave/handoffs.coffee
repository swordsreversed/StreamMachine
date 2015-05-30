# Test handing off live listeners from one slave to another, as we would
# during a graceful restart. Test that the listener connection stays
# alive through the restart and keeps receiving data.

MasterMode      = $src "modes/master"
SlaveMode       = $src "modes/slave"

StreamListener  = $src "util/stream_listener"
IcecastSource   = $src "util/icecast_source"

mp3 = $file "mp3/mp3-44100-128-s.mp3"

MasterHelper    = require "../helpers/master"
SlaveHelper     = require "../helpers/slave"

_ = require "underscore"
util = require "util"

debug = require("debug")("sm:tests:slave_handoffs")

master_info = null
source      = null

describe "Slave Handoffs and Worker Respawns", ->

    before (done) ->
        # unfortunately, to test slave mode, we need a master. that means
        # we get to do a lot here that hopefully gets tested elsewhere

        MasterHelper.startMaster "mp3", (err,info) ->
            throw err if err
            master_info = info

            source = new IcecastSource
                format:     "mp3"
                filePath:   mp3
                host:       "127.0.0.1"
                port:       master_info.source_port
                password:   master_info.source_password
                stream:     master_info.stream_key

            source.start (err) ->
                throw err if err
                done()

    describe "Worker Respawns", ->
        slave       = null
        slave_port  = null

        before (done) ->
            this.timeout(4000)
            SlaveHelper.startSlave master_info.slave_uri, 2, (err,slave_info) ->
                throw err if err

                slave = slave_info.slave

                slave.once "full_strength", ->
                    slave_port = slave._lastAddress.port
                    done()

        it "can accept a stream listener", (done) ->
            listener = new StreamListener "127.0.0.1", slave_port, master_info.stream_key

            listener.connect (err) =>
                throw err if err
                listener.disconnect()
                done()


        it "does not disconnect a listener while shutting down a worker", (done) ->
            this.timeout 5000

            listener = new StreamListener "127.0.0.1", slave_port, master_info.stream_key

            listener.connect (err) =>
                throw err if err

                debug "listener connected"

                slave.status (err,status) ->
                    worker = _(status).find (s) ->
                        s.streams[master_info.stream_key].listeners == 1

                    throw new Error("Failed to find worker with listener") if !worker

                    debug "listener is on worker #{ worker.id }"

                    # shut this worker down...
                    slave.shutdownWorker worker.id, (err) ->
                        throw err if err

                        debug "worker is shut down"

                        # our listener should still be getting data...
                        listener.once "bytes", ->
                            debug "listener got bytes"
                            done()

    describe "Slave Handoffs", ->
        slave       = null
        slave_port  = null

        xit "can start the first slave", (done) ->
            this.timeout(4000)
            SlaveHelper.startSlave master_info.slave_uri, 1, (err,slave_info) ->
                throw err if err

                slave = slave_info.slave

                slave.once "full_strength", ->
                    slave_port = slave._lastAddress.port
                    expect(slave_port).to.not.be.undefined
                    expect(slave_port).to.be.number
                    done()
