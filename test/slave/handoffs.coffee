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

RPC             = require "ipc-rpc"
RPCProxy        = $src "util/rpc_proxy"

cp = require "child_process"

_ = require "underscore"
util = require "util"

debug = require("debug")("sm:tests:slave_handoffs")

describe "Slave Handoffs and Worker Respawns", ->
    master_info = null
    source      = null

    before (done) ->
        # unfortunately, to test slave mode, we need a master. that means
        # we get to do a lot here that hopefully gets tested elsewhere

        MasterHelper.startMaster "mp3", (err,info) ->
            throw err if err
            master_info = info

            debug "started master. Connect at: #{master_info.slave_uri}"
            debug "Stream Key is #{master_info.stream_key}"

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
            this.timeout(10000)
            SlaveHelper.startSlave master_info.slave_uri, 2, (err,slave_info) ->
                throw err if err

                slave = slave_info.slave

                slave.once "full_strength", ->
                    slave_port = slave.slavePort()
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
        s1      = null
        s1rpc   = null
        s2      = null
        s2rpc   = null

        slave_config = null
        slave_port = null

        listener = null

        before (done) ->
            slave_config = [
                "--mode=slave"
                "--slave:master=#{master_info.slave_uri}",
                "--port=0",
                "--cluster=1",
                "--no-log:stdout"
            ]

            done()

        describe "Initial Slave", ->
            before (done) ->
                this.timeout 5000

                s1 = cp.fork "./index.js", slave_config
                process.on "exit", -> s1.kill()

                # wait a few ticks for startup...
                # FIXME: What's a better way to do this?
                setTimeout ->
                    new RPC s1, (err,r) ->
                        s1rpc = r
                        s1rpc.request "OK", (err,msg) ->
                            throw err if err

                            # FIXME: On Node 0.10, we run into an issue handling
                            # connections that arrive before we have a loaded
                            # worker. For the moment, simply make sure we have
                            # one here

                            s1rpc.request "ready", (err) ->
                                throw err if err

                                done()
                , 3000

            it "is listening on a port", (done) ->
                s1rpc.request "slave_port", (err,port) ->
                    throw err if err
                    slave_port = port
                    expect(port).to.be.number
                    done()

            it "can accept a listener connection", (done) ->
                debug "Connecting listener to 127.0.0.1:#{slave_port}/#{master_info.stream_key}"
                listener = new StreamListener "127.0.0.1", slave_port, master_info.stream_key

                listener.connect (err) =>
                    throw err if err

                    debug "listener connected"

                    listener.once "bytes", ->
                        debug "listener got bytes"
                        done()

        describe "New Slave", ->
            before (done) ->
                this.timeout 5000

                s2 = cp.fork "./index.js", ["--handoff",slave_config...]
                process.on "exit", -> s2.kill()

                # wait a few ticks for startup...
                # FIXME: What's a better way to do this?
                setTimeout ->
                    new RPC s2, (err,r) ->
                        s2rpc = r
                        s2rpc.request "OK", (err,msg) ->
                            throw err if err
                            done()
                , 3000

            it "should not immediately be listening on a port", (done) ->
                s2rpc.request "slave_port", (err,port) ->
                    throw err if err

                    expect(port).to.be.undefined

                    done()

        describe "Handoff", ->
            proxy = null

            before (done) ->
                # we need to disconnect our listeners, and then attach our proxy
                # RPC to bind the two together
                s1rpc.disconnect()
                s2rpc.disconnect()

                proxy = new RPCProxy s1, s2
                done()

            it "should run a handoff and initial slave should exit", (done) ->
                this.timeout 12000
                # we trigger the handoff by sending USR2 to s1
                s1.kill("SIGUSR2")

                proxy.on "error", (msg) =>
                    err = new Error msg.error
                    err.stack = msg.err_stack

                    throw err

                t = setTimeout =>
                    throw new Error "Initial slave did not exit within 10 seconds."
                , 10000

                s1.on "exit", (code) =>
                    expect(code).to.eql 0
                    clearTimeout t

                    proxy.disconnect()

                    new RPC s2, (err,r) ->
                        s2rpc = r
                        s2rpc.request "OK", (err,msg) ->
                            throw err if err
                            debug "s2rpc reconnected and got OK"
                            done()

            it "new slave should show a connected listener", (done) ->
                s2rpc.request "status", (err,status) ->
                    throw err if err
                    worker = _(status).find (s) ->
                        s.streams[master_info.stream_key].listeners == 1

                    throw new Error("Failed to find worker with listener") if !worker

                    done()

            it "listener should still receive data", (done) ->
                this.timeout 3000
                listener.once "bytes", ->
                    done()

            it "new slave should accept a new listener connection", (done) ->
                l2 = new StreamListener "127.0.0.1", slave_port, master_info.stream_key

                l2.connect (err) =>
                    throw err if err

                    l2.once "bytes", ->
                        done()
