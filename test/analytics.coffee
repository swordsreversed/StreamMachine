Analytics = $src "master/analytics"
Logger    = $src "logger"

nconf           = require "nconf"
elasticsearch   = require "elasticsearch"
URL             = require "url"
uuid            = require "node-uuid"
_               = require "underscore"

user_id     = uuid.v4()
session_id  = uuid.v4()

# started an hour ago
start_time = Number(new Date) - 60*60*1000

START =
    type:           "session_start"
    client:
        output:     "live_streaming"
        ip:         "1.2.3.4"
        path:       "/sg/test.m3u8"
        ua:         "StreamMachine Tests"
        user_id:    user_id
        session_id: session_id
    time:           new Date(start_time)
    stream_group:   "test"

describe "Analytics", ->
    analytics   = null
    es          = null

    sent_dur    = 0
    sent_bytes  = 0

    before (done) ->
        # connect to the db
        _uri = URL.parse @opts.es_uri

        es = new elasticsearch.Client
            host:       "http://#{_uri.hostname}:#{_uri.port||9200}"
            apiVersion: "1.1"

        done()

    describe "Startup", ->
        logger = new Logger {}

        it "starts up using config options", (done) ->
            analytics = new Analytics nconf.get("analytics"), logger

            expect(analytics).to.be.instanceof(Analytics)
            done()

        it "connects to Elasticsearch", (done) ->
            #expect(analytics.influx).to.be.instanceof(Influx)
            # FIXME: How do we test the connection?
            done()

        it "selects the last session time from the database"

    describe "Session Start", ->
        it "stores a session start", (done) ->
            analytics._log START, (err) ->
                expect(err).to.be.null

                # it should have set a timer for our session
                #expect(analytics.sessions).to.have.property(START.id)
                done()

        it "can retrieve the session start", (done) ->
            analytics._selectSessionStart START.id, (err,start) ->
                expect(err).to.be.null
                expect(start).to.be.object

                expect(start?.time).to.be.eql(START.start_time)
                expect(start?.client_uid).to.be.equal(START.client.user_id)
                done()

        it "should not find a previous session", (done) ->
            analytics._selectPreviousSession START.id, (err,ts) ->
                expect(err).to.be.null
                expect(ts).to.be.null
                done()

    describe "Listening", ->
        it "stores listen events", (done) ->
            listens = []
            _(60).times (i) ->
                listen =
                    type:       "listen"
                    client:     START.client
                    time:       new Date( start_time + i*10*1000 )
                    bytes:      300000
                    duration:   10.0
                    stream:     "test-256"

                listens.push listen
                sent_dur += listen.duration
                sent_bytes += listen.bytes

            lFunc = (cb) ->
                l = listens.shift()
                return cb() if !l
                analytics._log l, (err) ->
                    expect(err).to.be.null
                    lFunc cb

            lFunc ->
                done()

        it "totals listening correctly", (done) ->
            analytics._selectListenTotals START.id, null, (err,totals) ->
                expect(err).to.be.null

                expect(totals).to.be.object
                expect(totals.duration).to.eq sent_dur
                expect(totals.bytes).to.eq sent_bytes
                done()

        it "selects last listen correctly", (done) ->
            analytics._selectLastListen START.id, (err,ll) ->
                expect(err).to.be.null

                expect(ll).to.be.instanceof Date
                done()

    describe "Session Creation", ->
        session = null
        it "can create a session", (done) ->
            analytics._finalizeSession START.id, (err,sess) ->
                expect(err).to.be.null
                expect(sess).to.be.object
                session = sess
                done()

        it "gets bytes sent correct", (done) ->
            expect(session.bytes).to.eq sent_bytes
            done()

        it "gets duration sent correct", (done) ->
            expect(session.duration).to.eq sent_dur
            done()

        it "gets stream correct", (done) ->
            expect(session.stream).to.eq START.stream_group
            done()

        it "gets connected time correct", (done) ->
            expect(session.connected).to.be.within sent_dur-10, sent_dur
            done()

        it "stores session to database", (done) ->
            analytics._storeSession session, (err) ->
                expect(err).to.be.null

                # query session from influx
                influx.query "SELECT time FROM sessions WHERE id = '#{session.id}'", (err,res) ->
                    expect(err).to.be.null
                    expect(res).to.have.length 1
                    expect(res[0].points).to.have.length 1
                    expect(new Date(res[0].points[0][0])).to.be.eql session.time
                    done()
