_       = require "underscore"
Influx  = require "influx"
URL     = require "url"
winston = require "winston"
tz      = require "timezone"
nconf   = require "nconf"

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
    constructor: (@opts,@log) ->
        influx_uri = URL.parse @opts.influx
        influx_auth = influx_uri.auth?.split(":")
        @influx = new Influx influx_uri.hostname, influx_uri.port, influx_auth?[0], influx_auth?[1], influx_uri.path.substr(1)

        # track open sessions
        @sessions = {}

        @local = tz(require "timezone/zones")(nconf.get("timezone")||"UTC")

        # -- are there any sessions that should be finalized? -- #

        # when was our last finalized session?
        last_session = @influx.query "SELECT max(time) from sessions", (err,res) =>
            console.log "last session is ", err, res

        # what sessions have we seen since then?

    _log: (obj,cb) ->
        #console.log "Analytics: ", obj

        session_id = null

        if !obj.client?.session_id
            cb? new Error "Object does not contain a session ID"
            return false

        setFinalizeTimer = =>
            if t = @sessions[ obj.client.session_id ]
                clearTimeout t

            @sessions[ obj.client.session_id ] = setTimeout =>
                @_finalizeSession obj.client.session_id, (err,session) =>
                    if err
                        @log.error "Failed to finalize session: #{err}"
                        return false

                    @_storeSession session, (err) =>
                        if err
                            @log.error "Failed to store session: #{err}"
                            return false

            , 60*1000

            cb? null

        switch obj.type
            when "session_start"
                @influx.writePoint "starts",
                    time:           new Date(obj.time)
                    output:         obj.client.output
                    session_id:     obj.client.session_id
                    client_ip:      obj.client.ip
                    client_ua:      obj.client.ua
                    client_uid:     obj.client.user_id
                    path:           obj.client.path
                    stream:         obj.stream_group || obj.stream
                , (err) =>
                    if err
                        @log.error "Influx write error: #{err}"
                        return cb? err

                    setFinalizeTimer()


            when "listen"
                @influx.writePoint "listens",
                    time:           new Date(obj.time)
                    output:         obj.client.output
                    session_id:     obj.client.session_id
                    client_ip:      obj.client.ip
                    client_ua:      obj.client.ua
                    client_uid:     obj.client.user_id
                    path:           obj.client.path
                    bytes:          obj.bytes
                    duration:       obj.duration
                    stream:         obj.stream
                , (err) =>
                    if err
                        @log.error "Influx write error: #{err}"
                        return cb? err

                    setFinalizeTimer()

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

                    @_selectLastListen id, (err,ll) =>
                        if err
                            @log.error err
                            return cb? err

                        # -- build session -- #

                        session =
                            id:         id
                            output:     start.output
                            stream:     start.stream
                            time:       ts || start.time
                            client_ip:  start.client_ip
                            client_ua:  start.client_ua
                            client_uid: start.client_uid
                            bytes:      totals.bytes
                            duration:   totals.duration
                            connected:  ( Number(ll) - Number(ts||start.time) ) / 1000

                        cb null, session

    #----------

    _storeSession: (session,cb) ->
        @influx.writePoint "sessions", session, (err) =>
            if err
                @log.error "Influx write error: #{err}"
                return cb? err

            cb? null

    #----------

    _selectSessionStart: (id,cb) ->
        # -- Look up user information from session_start -- #

        @influx.query "SELECT stream,output,client_ip,client_ua,client_uid FROM starts WHERE session_id = '#{id}' LIMIT 1", (err,res) =>
            return cb new Error "Error querying session start for #{id}: #{err}" if err
            if res.length == 1
                start = pointsToObjects(res[0])[0]
                start.time = new Date(start.time)
                cb null, start
            else
                cb null, null

    #----------

    _selectPreviousSession: (id,cb) ->
        # -- Have we ever finalized this session id? -- #

        @influx.query "SELECT time from sessions where session_id = '#{ id }' LIMIT 1", (err,res) =>
            return cb new Error "Error querying for old session #{id}: #{err}" if err

            if res.length == 1
                cb null, res[0].points[0][0]
            else
                cb null, null

    #----------

    _selectListenTotals: (id,ts,cb) ->
        # -- Query total duration and bytes sent -- #

        query = "SELECT SUM(duration) as duration, SUM(bytes) as bytes FROM listens WHERE session_id = '#{ id }'"
        query += " AND time > #{ ts }" if ts

        @influx.query query, (err,res) =>
            return cb new Error "Error querying listens to finalize session #{id}: #{err}" if err
            if res.length == 1
                cb null, pointsToObjects(res[0])[0]
            else
                cb null, null

    #----------

    _selectLastListen: (id,cb) ->
        # -- Query time of last listen event -- #

        @influx.query "SELECT time FROM listens WHERE session_id = '#{id}' LIMIT 1", (err,res) =>
            return cb new Error "Error querying last listen for #{id}: #{err}" if err

            if res.length == 1
                cb null, new Date(res[0].points[0][0])
            else
                cb null, null

    #----------

    countListeners: (cb) ->
        # -- Query recent listeners -- #

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

