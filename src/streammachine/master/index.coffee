_u      = require "underscore"
temp    = require "temp"
net     = require "net"
fs      = require "fs"
express = require "express"

Redis       = require "../redis"
RedisConfig = require "../redis_config"
Admin       = require "./admin/router"
Stream      = require "./stream"
SourceIn    = require "./source_in"
Alerts      = require "../alerts"
Analytics   = require "./analytics"

RewindDumpRestore   = require "../rewind/dumper"

# A Master handles configuration, slaves, incoming sources, logging and the admin interface

module.exports = class Master extends require("events").EventEmitter
    DefaultOptions:
        max_zombie_life:    1000 * 60 * 60

    constructor: (opts) ->
        @options = _u.defaults opts||{}, @DefaultOptions

        @slaves         = {}
        @streams        = {}
        @stream_groups  = {}
        @proxies        = {}

        # -- set up logging -- #

        @log = @options.logger

        # -- look for hard-coded configuration -- #

        if @options.streams
            process.nextTick =>
                @configureStreams @options.streams

        # -- load our streams configuration from redis -- #

        if @options.redis?
            @log.debug "Initializing Redis connection"
            @redis = new Redis @options.redis
            @redis_config = new RedisConfig @redis
            @redis_config.on "config", (config) =>
                # stash the configuration
                @options = _u.defaults config||{}, @options

                # (re-)configure our master stream objects
                @configureStreams @options.streams

                # pass config on to any connected slaves
                for id,s of @slaves
                    s.sock.emit "config", @config()

            # Persist changed configuration to Redis
            @log.debug "Registering config_update listener"
            @on "config_update", =>
                @redis_config._update @config()

        # -- create a server to provide the admin -- #

        @admin = new Admin @

        # -- create a backend server for stream requests -- #

        @transport = new Master.StreamTransport @

        # -- start the source listener -- #

        @sourcein = new SourceIn core:@, port:opts.source_port

        # -- create an alerts object -- #

        @alerts = new Alerts logger:@log.child(module:"alerts")

        # set an interval to check monitored streams for sources
        setInterval =>
            for k,s of @streams
                @alerts.update "sourceless", s.key, !s.source? if s.opts.monitored
        , 5*1000

        # -- Analytics -- #

        if opts.analytics
            @analytics = new Analytics
                config: opts.analytics
                log:    @log.child(module:"analytics")
                redis:  @redis

            # add a log transport
            @log.logger.add new Analytics.LogTransport(@analytics), {}, true

        # -- Rewind Dump and Restore -- #

        @rewind_dr = new RewindDumpRestore @, opts.rewind_dump

    #----------

    listenForSlaves: (server) ->
        # fire up a socket listener on our slave port
        @io = require("socket.io").listen server

        @log.info "Master now listening for slave connections."

        # attach proxies for any streams that are already up
        @_attachIOProxy(s) for key,s of @streams

        # add our authentication
        @io.use (socket,next) =>
            @log.debug "Authenticating slave connection."
            if @options.master.password == socket.request._query?.password
                @log.debug "Slave password is valid."
                next()
            else
                @log.debug "Slave password is incorrect."
                next new Error "Invalid slave password."

        # look for slave connections
        @io.on "connection", (sock) =>
            # a slave may make multiple connections to test transports. we're
            # only interested in the one that gives us the OK
            sock.once "ok", (cb) =>
                # ping back to let the slave know we're here
                cb "OK"

                @log.debug "slave connection is #{sock.id}"

                if @options.streams
                    # emit our configuration
                    @log.debug "Sending config information to slave."
                    sock.emit "config", @config()

                @slaves[sock.id] =
                    sock:           sock
                    connected_at:   new Date()
                    status:         null
                    errors:         0

                # attach event handler for log reporting

                socklogger = @log.child slave:sock.id
                sock.on "log", (obj = {}) =>
                    socklogger[obj.level||'debug'].apply socklogger, [obj.msg||"",obj.meta||{}]

                sock.on "stream_stats", (key, cb) =>
                    # respond with the stream's vitals
                    @streams[key].vitals cb

                # attach disconnect handler
                sock.on "disconnect", =>
                    connected = Math.round( (Number(new Date()) - Number(@slaves[sock.id].connected_at)) / 1000 )
                    @log.debug "Slave disconnect from #{sock.id}. Connected for #{ connected } seconds."

                    delete @slaves[sock.id]

                    # set this in a timeout just in case we're mid-status at the time
                    setTimeout =>
                        # mark any alerts as cleared
                        for k in ["slave_unsynced","slave_unresponsive"]
                            @alerts.update k, sock.id, false
                    , 3000

        @on "config_update", =>
            config = @config()
            s.sock.emit "config", config for id,s of @slaves

        # -- Poll for Slave Status -- #

        @_slaveStatus = setInterval =>
            # -- what is our status? -- #

            mstatus = @_rewindStatus()

            # -- now check the slaves -- #

            for s,obj of @slaves
                do (s,obj) =>
                    pollTimeout = setTimeout =>
                        @log.error "Slave #{s} failed to respond to status."
                        @alerts.update "slave_unresponsive", s, true
                    , 1000

                    obj.sock.emit "status", (err,status) =>
                        clearTimeout pollTimeout
                        @alerts.update "slave_unresponsive", s, false

                        if err
                            @log.error "Slave #{s} reported status error: #{err}"
                            return false

                        obj.status = status

                        # -- are the rewind buffers synced to ours? -- #

                        # For this we need to run through each stream, and then
                        # through each value inside to see if it is within an
                        # acceptable range

                        unsynced = false

                        for key,mobj of mstatus
                            if sobj = status[key]
                                for ts in ["first_buffer_ts","last_buffer_ts"]
                                    sts = Number(new Date(sobj[ts]))
                                    mts = Number(mobj[ts])

                                    if ( _u.isNaN(sts) && _u.isNaN(mts) ) || (mts - 10*1000) < sts < (mts + 10*1000)
                                        # ok
                                    else
                                        @log.info "Slave #{s} sync unhealthy on #{key}:#{ts}", sts, mts
                                        unsynced = true

                            else
                                unsynced = true

                        @alerts.update "slave_unsynced", s, unsynced

        , 5 * 1000

    #----------

    config: ->
        config = streams:{}

        config.streams[k] = s.config() for k,s of @streams

        return config

    #----------

    # configureStreams can be called on a new core, or it can be called to
    # reconfigure an existing core.  we need to support either one.
    configureStreams: (options,cb) ->
        @log.debug "In configure with ", options

        # -- Sources -- #

        # are any of our current streams missing from the new options? if so,
        # disconnect them
        for k,obj of @streams
            @log.debug "calling destroy on ", k
            if !options?[k]
                obj.destroy()
                delete @streams[ k ]

        # run through the streams we've been passed, initializing sources and
        # creating rewind buffers
        for key,opts of options
            @log.debug "Parsing stream for #{key}"
            if @streams[key]
                # existing stream...  pass it updated configuration
                @log.debug "Passing updated config to master stream: #{key}", opts:opts
                @streams[key].configure opts
            else
                @log.debug "Starting up master stream: #{key}", opts:opts
                @_startStream key, opts

            # part of a stream group?
            if g = @streams[key].opts.group
                # do we have a matching group?
                sg = ( @stream_groups[ g ] ||= new Stream.StreamGroup g, @log.child stream_group:g )
                sg.addStream @streams[key]

        @emit "streams", @streams

        cb? null, @streams

    #----------

    _startStream: (key,opts) ->
        stream = new Stream @, key, @log.child(stream:key), opts

        if stream
            # attach a listener for configs
            stream.on "config", => @emit "config_update"; @emit "streams", @streams

            @streams[ key ] = stream
            @_attachIOProxy stream
            return stream
        else
            return false

    #----------

    createStream: (opts,cb) ->
        @log.debug "createStream called with ", opts

        # -- make sure the stream key is present and unique -- #

        if !opts.key
            cb? "Cannot create stream without key."
            return false

        if @streams[ opts.key ]
            cb? "Stream key must be unique."
            return false

        # -- create the stream -- #

        if stream = @_startStream opts.key, opts
            @emit "config_update"
            @emit "streams"
            cb? null, stream.status()
        else
            cb? "Stream failed to start."

    #----------

    updateStream: (stream,opts,cb) ->
        @log.info "updateStream called for ", key:stream.key, opts:opts

        # -- if they want to rename, the key must be unique -- #

        if stream.key != opts.key
            if @streams[ opts.key ]
                cb? "Stream key must be unique."
                return false

            @streams[ opts.key ] = stream
            delete @streams[ stream.key ]

        # -- if we're good, ask the stream to configure -- #

        stream.configure opts, (err,config) =>
            if err
                cb? err
                return false


            cb? null, config

    #----------

    removeStream: (stream,cb) ->
        @log.info "removeStream called for ", key:stream.key

        delete @streams[ stream.key ]
        stream.destroy()

        @emit "config_update"

        cb? null, "OK"

    #----------

    streamsInfo: ->
        obj.status() for k,obj of @streams

    groupsInfo: ->
        obj.status() for k,obj of @stream_groups

    #----------

    # Get a status snapshot by looping through each stream to get buffer stats
    _rewindStatus: ->
        status = {}
        status[ key ] = s.rewind._rStatus() for key,s of @streams
        status

    #----------

    slavesInfo: ->
        slaveCount: Object.keys(@slaves).length
        slaves: ( { id:k, status:s.status } for k,s of @slaves )
        master: @_rewindStatus()

    #----------

    sendHandoffData: (translator,cb) ->
        # -- Send Rewind buffers -- #

        @log.info "Sending Rewind buffers for handoff."

        fFunc = _u.after Object.keys(@streams).length, =>
            @log.info "Rewind buffers and sources sent."
            cb null

        lFunc = (stream) =>
            if stream.rewind.bufferedSecs() > 0
                # create a socket
                spath = temp.path suffix:".sock"

                @log.info "Sending rewind buffer for #{stream.key} over #{spath}."

                sock = net.createServer (c) =>
                    # write the buffer to the socket
                    @log.info "Got socket connection on #{spath}"

                    stream.rewind.dumpBuffer c, =>
                        @log.info "Dumped buffer for #{stream.key}", bytesWritten:c.bytesWritten

                        c.on "close", (err) =>
                            @log.info "Rewind buffer sock is done.", error:err

                            # cleanup...
                            sock.close => fs.unlink spath, (err) =>
                                @log.info "RewindBuffer socket unlinked.", error:err

                            fFunc()

                sock.listen spath

                sock.on "listening", =>
                    # pass the socket to the new child and wait for acknowledgement
                    translator.send "master_rewind", { stream:stream.key, path:spath, rsecsPerChunk:stream.rewind._rsecsPerChunk }

                # OK!
            else
                fFunc()

            # -- send source connections -- #

            sFunc = (source) ->
                if source.sock
                    translator.send "stream_source", { stream:stream.key, headers:source.headers, uuid:source.uuid }, source.sock

            for source in stream.sources
                sFunc(source)

        # run 'em
        lFunc(s) for k,s of @streams

    #----------

    loadHandoffData: (translator,cb) ->
        # listen for the start of RewindBuffer transactions
        translator.on "master_rewind", (data) =>
            @log.info "Got Rewind load signal for #{data.stream} on #{data.path}"

            # set emit duration on the rewinder if the source hasn't
            # connected yet
            @streams[ data.stream ].rewind._rChunkLength data.rsecsPerChunk

            # create a socket connection
            sock = net.connect path:data.path, allowHalfOpen:true, =>
                @streams[ data.stream ].rewind.loadBuffer sock, (err) =>
                    @log.info "Loaded rewind buffer.", bytesRead:sock.bytesRead
                    sock.end()

        # listen for source connections
        translator.on "stream_source", (data,sock) =>
            @log.info "Got source socket for #{data.stream}"
            stream = @streams[ data.stream ]

            #sock = new net.Socket fd:handle, type:"tcp4"
            source = new (require "../sources/icecast") stream, sock, data.headers, data.uuid
            stream.addSource source

    #----------

    _attachIOProxy: (stream) ->
        @log.debug "attachIOProxy call for #{stream.key}.", io:@io?, proxy:@proxies[stream.key]?
        return false if !@io

        if @proxies[ stream.key ]
            return false

        # create a new proxy
        @log.debug "Creating StreamProxy for #{stream.key}"
        @proxies[ stream.key ] = new Master.StreamProxy key:stream.key, stream:stream, master:@

        # and attach a listener to destroy it if the stream is removed
        stream.once "destroy", =>
            @proxies[ stream.key ]?.destroy()

    #----------

    class @StreamTransport
        constructor: (@master) ->
            @app = express()

            # -- Param Handlers -- #

            @app.param "stream", (req,res,next,key) =>
                # make sure it's a valid stream key
                if key? && s = @master.streams[ key ]
                    req.stream = s
                    next()
                else
                    res.status(404).end "Invalid stream.\n"

            # -- Validate slave id -- #

            @app.use (req,res,next) =>
                sock_id = req.get 'stream-slave-id'
                if sock_id && @master.slaves[ sock_id ]
                    req.slave_socket = @master.slaves[ sock_id ]
                    next()

                else
                    @master.log.debug "Rejecting StreamTransport request with missing or invalid socket ID.", sock_id:sock_id
                    res.status(401).end "Missing or invalid socket ID.\n"

            # -- Routes -- #

            @app.get "/:stream/rewind", (req,res) =>
                @master.log.debug "Rewind Buffer request from slave on #{req.stream.key}."
                res.status(200).write ''
                req.stream.rewind.dumpBuffer res, (err) =>
                    @master.log.debug "Rewind dumpBuffer finished."
                    #res.end()

    #----------

    class @StreamProxy extends require("events").EventEmitter
        constructor: (opts) ->
            @key = opts.key
            @stream = opts.stream
            @master = opts.master

            @dataFunc = (chunk) =>
                for id,s of @master.slaves
                    s.sock.emit "streamdata:#{@key}", chunk

            @stream.on "data", @dataFunc

        destroy: ->
            @stream.removeListener "data", @dataFunc

    #----------