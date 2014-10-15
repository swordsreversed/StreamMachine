RewindBuffer    = $src "rewind_buffer"
FileSource      = $src "sources/file"
Logger          = $src "logger"

nconf = require "nconf"

uuid = require "node-uuid"
fs = require "fs"

mp3_a = $file "mp3/mp3-44100-64-s.mp3"

describe "Rewind Buffer Dump and Restore", ->
    rewind      = null
    source_a    = null

    logger = new Logger stdout:true

    run_id = uuid.v4()

    nconf.set "rewind_dump:dir", "/tmp"
    nconf.set "rewind_dump:frequency", -1

    dump_filepath = null

    after (done) ->
        # make sure our file gets removed
        fs.unlinkSync dump_filepath if dump_filepath
        done()

    describe "When dumping", ->
        before (done) ->
            rewind = new RewindBuffer seconds:120, burst:30, log:logger, key:"test__#{run_id}"
            rewind.log = logger

            done()

        before (done) ->
            source = new FileSource format:"mp3", filePath:mp3_a, do_not_emit:true
            rewind._rConnectSource source, ->
                console.log "Source is connected."

                process.nextTick ->
                    ts = Number(new Date)
                    # push two minutes of data (240 samples)
                    for i in [0..239]
                        c_ts = new Date(ts+source.emitDuration*1000*i)
                        source._emitOnce(c_ts)

                    done()

        it "should have 120 seconds in the buffer", (done) ->
            expect( rewind.bufferedSecs() ).to.be.within 119, 121
            done()

        it "should be able to dump its buffer", (done) ->
            rewind._dump._dump (err,fp) ->
                throw err if err

                dump_filepath = fp

                stat = fs.statSync(dump_filepath)

                expect(stat.size).to.be.gt 7000
                done()

    describe "When restoring", ->
        before (done) ->
            rewind = new RewindBuffer seconds:120, burst:30, log:logger, key:"test__#{run_id}"
            rewind.log = logger

            done()

        it "should load with a status of true", (done) ->
            rewind._dump.once_loaded (status) ->
                expect(status).to.eql true
                done()

        it "should have 120 seconds in the buffer", (done) ->
            expect( rewind.bufferedSecs() ).to.be.within 119, 121
            done()
