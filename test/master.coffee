MasterMode      = $src "modes/master"
Master          = $src "master"
MasterStream    = $src "master/stream"

nconf   = require "nconf"
_       = require "underscore"

STREAM1 = 
    key:                "test1"
    source_password:    "abc123"
    root_route:         true
    seconds:            60*60*4
    format:             "mp3"

describe "StreamMachine Master Mode", ->
    mm = null
    
    port_master = null
    port_source = null

    # -- Update some config -- #
    
    nconf.overrides
        "master:port":      0
        "source_port":      0

    nconf.clear("redis")

    # -- Initialize our master -- #

    before (done) ->
        new MasterMode nconf.get(), (err,m) =>
            return throw err if err
            
            mm = m
            
            port_master = mm.master.handle?.address().port
            port_source = mm.master.sourcein?.server?.address().port
            
            done()
    
    # -- Test our startup state -- #
    
    describe "Startup", ->
        it "should have started a Master instance", (done) ->
            expect(mm.master).to.be.a.instanceof(Master)
            done()
            
        it "should be listening on a source port", (done) ->
            expect(port_source).not.to.be.null
            done()
        
        it "should be listening on an admin port", (done) ->
            expect(port_master).not.to.be.null
            done()
            
        it "should have no streams configured", (done) ->
            expect(mm.master.streams).to.be.empty
            done()
            
        it "should have no slaves", (done) ->
            expect(mm.master.slaves).to.be.empty
            done()
            
        it "should be listening for slaves"
    
    # -- Configure a Stream -- #
    
    describe "Stream Configuration", ->
        streams_emitted = false
        before (done) ->
            mm.master.once "streams", -> streams_emitted = true
            done()
        
        it "should accept a new stream", (done) ->
            c = {}
            c[ STREAM1.key ] = STREAM1
            
            mm.master.configureStreams c, (err,streams) ->
                expect(err).to.be.null
                expect(streams).to.have.property STREAM1.key
                expect(streams?[STREAM1.key]).to.be.an.instanceof MasterStream
                done()
                
        it "should have emitted 'streams' when configured", (done) ->
            expect(streams_emitted).to.be.true
            done()
            
    # -- Slaves -- #
    
    describe "Slave Connections", ->
        # TODO: implement good connect in a before so we can use it in 
        # multiple tests
        
        it "should allow a slave connection"
        
        it "should deny a slave that provides the wrong password"
        
        it "should have emitted configuration to the slave"
        
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