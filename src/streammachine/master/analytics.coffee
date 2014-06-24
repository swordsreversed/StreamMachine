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
                cb err
            else
                # do something...
                cb? null, @

        # -- are there any sessions that should be finalized? -- #

        # when was our last finalized session?
        #last_session = @influx.query "SELECT max(time) from sessions", (err,res) =>
        #    console.log "last session is ", err, res

        # what sessions have we seen since then?

    #----------

    _loadTemplates: (cb) ->
        errors = []

        _loaded = _.after Object.keys(Analytics.EStemplates).length, =>
            if errors.length > 0
                cb new Error "Failed to load index templates: #{ errors.join(" | ") }"
            else
                cb null

        for t,obj of Analytics.EStemplates
            console.log "Loading mappings for #{t}"
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


    #----------

    # Given a session id and duration, add the given duration to any
    # existing cached duration and return the accumulated number
    _getStashedDurationFor: (session,duration,cb) ->
        if @redis
            # use redis stash
            @redis.incrby session, duration, cb

        else
            # use memory stash
            s = @_ensureMemorySession session
            s.duration += duration
            cb null, s.duration

    #----------

    _ensureMemorySession: (session) ->
        @sessions[ session ] ||= duration:0, last_seen_at:Number(new Date())

    #----------

    _finalizeSession: (id,cb) ->
        @log.debug "Finalizing session for #{ id }"

        # This is a little ugly. We need to take several steps:
        # 1) Have we ever finalized this session id? If so, then what?????
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
                    return cb? err

                if !start
                    err = "Failed to query session start for #{id}."
                    @log.error err
                    return cb? err

                @_selectListenTotals id, ts, (err,totals) =>
                    if err
                        @log.error err
                        return cb? err

                    if !totals
                        err = "No totals found for session #{ id }"
                        @log.debug err
                        return cb? err

                    # -- build session -- #

                    session =
                        session_id: id
                        output:     start.output
                        stream:     start.stream
                        time:       ts || start.time
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

        @es.search type:"start", body:body, index:"#{@idx_prefix}-listens-*", (err,res) =>
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


        @es.search type:"session", body:body, index:"#{@idx_prefix}-sessions-*", (err,res) =>
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

        @es.search type:"listen", index:"#{@idx_prefix}-listens-*", body:body, (err,res) =>
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

    countListeners: (cb) ->
        # -- Query recent listeners -- #

        return cb new Error "Not implemented."

        @influx.query "SELECT SUM(duration) AS seconds FROM listens GROUP BY time(1m) fill(0) LIMIT 15", (err,res) =>
            return cb new Error "Failed to query listens: #{err}" if err

            if res.length == 1
                timepoints = for p in res[0].points[1..-1]
                    tp =
                        time:       @local(p[0],"%F %T%^z")
                        listeners:  Math.round(p[1] / 60)

                console.log "calling back with ", timepoints
                cb null, timepoints

            else
                cb "Unknown error querying listening time."

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


