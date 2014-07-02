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
    idx_prefix  = null

    sent_dur    = 0
    sent_bytes  = 0
    last_ts     = null

    before (done) ->
        # connect to the db
        _uri = URL.parse(nconf.get("analytics:es_uri"))

        es = new elasticsearch.Client
            host:       "http://#{_uri.hostname}:#{_uri.port||9200}"
            apiVersion: "1.1"

        idx_prefix = _uri.pathname.substr(1)

        # -- Clear out old test data -- #

        es.indices.deleteTemplate name:"#{idx_prefix}-*", ignore:404, (err) ->
            throw err if err

            es.indices.delete index:"#{idx_prefix}-*", ignore:404, (err) ->
                throw err if err

                done()

    #----------

    beforeEach (done) ->
        # refresh the indices between each test, since otherwise documents
        # wouldn't be ready for searching as quickly as we're trying to
        # access them.

        es.indices.refresh index:"#{idx_prefix}-*", (err) ->
            throw err if err
            done()

    describe "Startup", ->
        logger = new Logger {}

        it "starts up using config options", (done) ->
            analytics = new Analytics config:nconf.get("analytics"), log:logger, (err) ->
                expect(err).to.be.null

                expect(analytics).to.be.instanceof(Analytics)
                done()

        it "connects to Elasticsearch", (done) ->
            # FIXME: How do we test the connection?
            done()

        it "puts index templates under our prefix", (done) ->
            okF = _.after 2, ->
                done()

            for t in ["sessions","listens"]
                do (t) ->
                    es.indices.getTemplate name:"#{idx_prefix}-#{t}-template", (err) ->
                        if err
                            console.error "Failed to find template: #{idx_prefix}-#{t}-template"

                        expect(err).to.be.undefined
                        okF()

        it "selects the last session time from the database"

        describe "Index Selection", ->
            it "chooses indices from a time range", (done) ->
                start   = new Date()
                end     = new Date( Number(start) - 86400*2*1000 )

                analytics._indicesForTimeRange "listens", start, end, (err,indices) ->
                    throw err if err

                    expect(indices).to.have.length 3
                    done()

            it "chooses indices given a start and offset", (done) ->
                start = new Date()

                analytics._indicesForTimeRange "listens", start, "-24 hours", (err,indices) ->
                    throw err if err

                    expect(indices).to.have.length 2
                    done()

            it "chooses one index given a single time", (done) ->
                start = new Date()

                analytics._indicesForTimeRange "listens", start, (err,indices) ->
                    throw err if err

                    expect(indices).to.have.length 1
                    done()

    describe "Session Start", ->
        it "stores a session start", (done) ->
            console.log "Storing session #{ START.client.session_id }"
            analytics._log START, (err) ->
                expect(err).to.be.null
                done()

        it "can retrieve the session start", (done) ->
            analytics._selectSessionStart START.client.session_id, (err,start) ->
                expect(err).to.be.null
                expect(start).to.not.be.null

                expect(start?.time).to.be.eql(START.time)
                expect(start?.client?.user_id).to.be.equal(START.client.user_id)
                done()

        it "should not find a previous session", (done) ->
            analytics._selectPreviousSession START.client.session_id, (err,ts) ->
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
                sent_dur    += listen.duration
                sent_bytes  += listen.bytes
                last_ts     = listen.time

            lFunc = (cb) ->
                l = listens.shift()
                return cb() if !l
                analytics._log l, (err) ->
                    expect(err).to.be.null
                    lFunc cb

            lFunc ->
                done()

        describe "Totals", ->
            totals = null

            it "totals listening correctly", (done) ->
                analytics._selectListenTotals START.client.session_id, null, (err,t) ->
                    expect(err).to.be.null

                    totals = t

                    expect(totals).to.be.object
                    expect(totals.duration).to.eq sent_dur
                    expect(totals.bytes).to.eq sent_bytes
                    done()

            it "selects last listen correctly", (done) ->
                expect(totals.last_listen).to.be.instanceof Date
                expect(totals.last_listen).to.eql last_ts
                done()

    describe "Session Creation", ->
        session = null
        it "can create a session", (done) ->
            analytics._finalizeSession START.client.session_id, (err,sess) ->
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
                expect(err).to.be.undefined
                done()

        it "session can be retrieved", (done) ->
            es.search index:"#{idx_prefix}-sessions-*", type:"session", size:1, (err,res) =>
                expect(err).to.be.undefined

                expect(res.hits.total).to.eql 1

                s = res.hits.hits[0]._source

                expect(s.session_id).to.eql session.session_id
                expect(s.client.user_id).to.eql START.client.user_id
                expect(s.bytes).to.eql sent_bytes

                done()
