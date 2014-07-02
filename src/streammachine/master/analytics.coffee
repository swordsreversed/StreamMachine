_       = require "underscore"
Influx  = require "influx"
URL     = require "url"
winston = require "winston"
tz      = require "timezone"
nconf   = require "nconf"
elasticsearch = require "elasticsearch"

pointsToObjects = (res) ->
    return null if !res

    objects = []
    # convert res.columns and the arrays in res.points to objects with keys
    keys = res.columns

    for p in res.points||[]
        objects.push _.object(keys,p)

    objects

# This module is responsible for:

# * Listen for session_start and listen interactions
# * Watch for sessions that are no longer active.  Finalize them, attaching
#   stats and duration, and throwing out sessions that did not meet minimum
#   requirements
# * Answer questions about current number of listeners at any given time
# * Produce old-style w3c output for listener stats

module.exports = class Analytics
    constructor: (@opts,cb) ->
        @_uri = URL.parse @opts.config.es_uri

        @log = @opts.log

        @_timeout_sec = Number(@opts.config.finalize_secs)

        if @opts.redis

            @redis = @opts.redis.client

        @es = new elasticsearch.Client
            host:       "http://#{@_uri.hostname}:#{@_uri.port||9200}"
            apiVersion: "1.1"

        @idx_prefix = @_uri.pathname.substr(1)

        # track open sessions
        @sessions = {}

        @local = tz(require "timezone/zones")(nconf.get("timezone")||"UTC")

        # -- Load our Templates -- #

        @_loadTemplates (err) =>
            if err
                console.error err
                cb? err
            else
                # do something...
                cb? null, @

        # -- are there any sessions that should be finalized? -- #

        # when was our last finalized session?
        #last_session = @influx.query "SELECT max(time) from sessions", (err,res) =>
        #    console.log "last session is ", err, res

        # what sessions have we seen since then?

        # -- Redis Session Sweep -- #

        if @redis
            @log.info "Analytics setting up Redis session sweeper"

            setInterval =>
                # look for sessions that should be written (score less than now)
                @redis.zrangebyscore "session-timeouts", 0, Math.floor( Number(new Date) / 1000), (err,sessions) =>
                    return @log.error "Error fetching sessions to finalize: #{err}" if err

                    _sFunc = =>
                        if s = sessions.shift()
                            @_triggerSession s
                            _sFunc()

                    _sFunc()

            , 5*1000

    #----------

    _loadTemplates: (cb) ->
        errors = []

        _loaded = _.after Object.keys(Analytics.EStemplates).length, =>
            if errors.length > 0
                cb new Error "Failed to load index templates: #{ errors.join(" | ") }"
            else
                cb null

        for t,obj of Analytics.EStemplates
            @log.info "Loading Elasticsearch mappings for #{@idx_prefix}-#{t}"
            tmplt = _.extend {}, obj, template:"#{@idx_prefix}-#{t}-*"
            @es.indices.putTemplate name:"#{@idx_prefix}-#{t}-template", body:tmplt, (err) =>
                errors.push err if err
                _loaded()

    #----------

    _log: (obj,cb) ->
        session_id = null

        if !obj.client?.session_id
            cb? new Error "Object does not contain a session ID"
            return false

        # write one index per day of data
        index_date = tz(obj.time,"%F")

        switch obj.type
            when "session_start"
                @es.index index:"#{@idx_prefix}-listens-#{index_date}", type:"start", body:
                    time:       new Date(obj.time)
                    session_id: obj.client.session_id
                    stream:     obj.stream_group || obj.stream
                    client:     obj.client
                , (err) =>
                    if err
                        @log.error "ES write error: #{err}"
                        return cb? err

                    cb? null

                # -- start tracking the session -- #

            when "listen"
                # do we know of other duration for this session?
                @_getStashedDurationFor obj.client.session_id, obj.duration, (err,dur) =>
                    @es.index index:"#{@idx_prefix}-listens-#{index_date}", type:"listen", body:
                        session_id:         obj.client.session_id
                        time:               new Date(obj.time)
                        bytes:              obj.bytes
                        duration:           obj.duration
                        session_duration:   dur
                        stream:             obj.stream
                        client:             obj.client
                    , (err) =>
                        if err
                            @log.error "ES write error: #{err}"
                            return cb? err

                        cb? null

        # -- update our timer -- #

        @_updateSessionTimerFor obj.client.session_id, (err) =>


    #----------

    # Given a session id and duration, add the given duration to any
    # existing cached duration and return the accumulated number
    _getStashedDurationFor: (session,duration,cb) ->
        if @redis
            # use redis stash
            key = "duration-#{session}"
            @redis.incrby key, Math.round(duration), (err,res) =>
                cb err, res

            # set a TTL on our key, so that it doesn't stay indefinitely
            @redis.pexpire key, 5*60*1000, (err) =>
                @log.error "Failed to set Redis TTL for #{key}: #{err}" if err

        else
            # use memory stash
            s = @_ensureMemorySession session
            s.duration += duration
            cb null, s.duration

    #----------

    _updateSessionTimerFor: (session,cb) ->
        if @redis
            # this will set the score, or update it if the session is
            # already in the set
            timeout_at = (Number(new Date) / 1000) + @_timeout_sec

            @redis.zadd "session-timeouts", timeout_at, session, (err) =>
                cb err

        else
            s = @_ensureMemorySession session

            clearTimeout s.timeout if s.timeout

            s.timeout = setTimeout =>
                @_triggerSession session
            , @_timeout_sec * 1000

            cb null

    #----------

    _scrubSessionFor: (session,cb) ->
        if @redis
            @redis.zrem "session-timeouts", session, (err) =>
                return cb err if err

                @redis.del "duration-#{session}", (err) =>
                    cb err

        else
           s = @_ensureMemorySession session
           clearTimeout s.timeout if s.timeout
           delete @sessions[session]

           cb null


    #----------

    _ensureMemorySession: (session) ->
        @sessions[ session ] ||=
            duration:0, last_seen_at:Number(new Date()), timeout:null

    #----------

    _triggerSession: (session) ->
        @_scrubSessionFor session, (err) =>
            return @log.error "Error cleaning session cache: #{err}" if err

            @_finalizeSession session, (err,obj) =>
                return @log.error "Error assembling session: #{err}" if err

                if obj
                    @_storeSession obj, (err) =>
                        @log.error "Error writing session: #{err}" if err

    #----------

    _finalizeSession: (id,cb) ->
        @log.silly "Finalizing session for #{ id }"

        # This is a little ugly. We need to take several steps:
        # 1) Have we ever finalized this session id?
        # 2) Look up the session_start for the session_id
        # 3) Compute the session's sent bytes, sent duration, and elapsed duration
        # 4) Write a session object

        session = {}

        # -- Get Started -- #

        @_selectPreviousSession id, (err,ts) =>
            if err
                @log.error err
                return cb? err

            @_selectSessionStart id, (err,start) =>
                if err
                    @log.error err
                    return cb err

                if !start
                    @log.debug "Attempt to finalize invalid session. No start event for #{id}."
                    return cb null, false

                @_selectListenTotals id, ts, (err,totals) =>
                    if err
                        @log.error err
                        return cb? err

                    if !totals
                        # Session did not have any recorded listen events.  Toss it.
                        return cb null, false

                    # -- build session -- #

                    session =
                        session_id: id
                        output:     start.output
                        stream:     start.stream
                        time:       totals.last_listen
                        start_time: ts || start.time
                        client:     start.client
                        bytes:      totals.bytes
                        duration:   totals.duration
                        connected:  ( Number(totals.last_listen) - Number(ts||start.time) ) / 1000

                    cb null, session

    #----------

    _storeSession: (session,cb) ->
        # write one index per day of data
        index_date = tz(session.time,"%F")

        @es.index index:"#{@idx_prefix}-sessions-#{index_date}", type:"session", body:session, (err) =>
            cb err

    #----------

    _selectSessionStart: (id,cb) ->
        # -- Look up user information from session_start -- #

        body =
            query:
                constant_score:
                    filter:
                        term:
                            "session_id":id
            sort:
                time:{order:"desc"}
            size:1

        # session start is allowed to be anywhere in the last 72 hours
        # FIXME: Is this reasonable? What do we want to do with long sessions?
        @_indicesForTimeRange "listens", new Date(), "-72 hours", (err,indices) =>
            @es.search type:"start", body:body, index:indices, ignoreUnavailable:true, (err,res) =>
                return cb new Error "Error querying session start for #{id}: #{err}" if err

                if res.hits.hits.length > 0
                    cb null, _.extend {}, res.hits.hits[0]._source, time:new Date(res.hits.hits[0]._source.time)
                else
                    cb null, null

    #----------

    _selectPreviousSession: (id,cb) ->
        # -- Have we ever finalized this session id? -- #

        body =
            query:
                constant_score:
                    filter:
                        term:
                            "session_id":id
            sort:
                time:{order:"desc"}
            size:1


        @_indicesForTimeRange "sessions", new Date(), "-72 hours", (err,indices) =>
            @es.search type:"session", body:body, index:indices, ignoreUnavailable:true, (err,res) =>
                return cb new Error "Error querying for old session #{id}: #{err}" if err

                if res.hits.hits.length == 0
                    cb null, null
                else
                    cb null, new Date(res.hits.hits[0]._source.time)

    #----------

    _selectListenTotals: (id,ts,cb) ->
        # -- Query total duration and bytes sent -- #

        filter =
            if ts
                "and":
                    filters:[
                        { range:{ time:{ gt:ts } } },
                        { term:{session_id:id} }
                    ]
            else
               term:{session_id:id}

        body =
            query:
                constant_score:
                    filter:filter
            aggs:
                duration:
                    sum:{ field:"duration" }
                bytes:
                    sum:{ field:"bytes" }
                last_listen:
                    max:{ field:"time" }

        @_indicesForTimeRange "listens", new Date(), ts||"-72 hours", (err,indices) =>
            @es.search type:"listen", index:indices, body:body, ignoreUnavailable:true, (err,res) =>
                return cb new Error "Error querying listens to finalize session #{id}: #{err}" if err

                if res.hits.total > 0
                    cb null,
                        requests:       res.hits.total
                        duration:       res.aggregations.duration.value
                        bytes:          res.aggregations.bytes.value
                        last_listen:    new Date(res.aggregations.last_listen.value)
                else
                    cb null, null

    #----------

    _indicesForTimeRange: (idx,start,end,cb) ->
        if _.isFunction(end)
            cb = end
            end = null

        start = @local(start)

        if _.isString(end) && end[0] == "-"
            end = @local(start,end)

        indices = []
        if end
            end = @local(end)

            s = start
            while true
                s = @local(s,"-1 day")
                break if s < end
                indices.push "#{@idx_prefix}-#{idx}-#{ @local(s,"%F") }"

        indices.unshift "#{@idx_prefix}-#{idx}-#{ @local(start,"%F") }"
        cb null, _.uniq(indices)

    #----------

    countListeners: (cb) ->
        # -- Query recent listeners -- #

        body =
            query:
                constant_score:
                    filter:
                        range:
                            time:
                                gt:"now-15m"
            size:0
            aggs:
                listeners_by_minute:
                    date_histogram:
                        field:      "time"
                        interval:   "minute"
                    aggs:
                        duration:
                            sum:{ field:"duration" }
                        sessions:
                            cardinality:{ field:"session_id" }
                        streams:
                            terms:{ field:"stream", size:5 }

        @_indicesForTimeRange "listens", new Date(), "-15 minutes", (err,indices) =>
            @es.search index:indices, type:"listen", body:body, ignoreUnavailable:true, (err,res) =>
                return cb new Error "Failed to query listeners: #{err}" if err

                times = []

                for obj in res.aggregations.listeners_by_minute.buckets
                    streams = {}
                    for sobj in obj.streams.buckets
                        streams[ sobj.key ] = sobj.doc_count

                    times.unshift
                        time:               @local(new Date(obj.key),"%F %T%^z")
                        requests:           obj.doc_count
                        avg_listeners:      Math.round( obj.duration.value / 60 )
                        sessions:           obj.sessions.value
                        requests_by_stream: streams

                cb null, times

    #----------

    class @LogTransport extends winston.Transport
        name: "analytics"

        constructor: (@a) ->
            super level:"interaction"

        log: (level,msg,meta,cb) ->
            if level == "interaction"
                @a._log meta
                cb?()

    #----------

    @ESobjcore:
        time:
            type:   "date"
            format: "date_time"
        stream:
            type:   "string"
            index:  "not_analyzed"
        session_id:
            type:   "string"
            index:  "not_analyzed"
        client:
            type:   "object"
            properties:
                session_id:
                    type:   "string"
                    index:  "not_analyzed"
                user_id:
                    type:   "string"
                    index:  "not_analyzed"
                output:
                    type:   "string"
                    index:  "not_analyzed"
                ip:
                    type:   "ip"
                ua:
                    type:   "string"
                path:
                    type:   "string"

    @EStemplates:
        sessions:
            mappings:
                session:
                    properties: _.extend {}, @ESobjcore,
                        duration:
                            type:   "float"
                            include_in_all: false
                        bytes:
                            type:   "integer"
                        ips:
                            type:   "ip"
                            index_name: "ip"
        listens:
            mappings:
                start:
                    properties: _.extend {}, @ESobjcore

                listen:
                    properties:
                        _.extend {}, @ESobjcore,
                            duration:
                                type:   "float"
                                include_in_all: false
                            bytes:
                                type:   "integer"


