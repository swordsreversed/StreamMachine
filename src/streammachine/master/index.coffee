_u = require "underscore"

Logger  = require "../log_controller"
Redis   = require "../redis_config"
Admin   = require "./admin/router"
Stream  = require "./stream"
SourceIn = require "./source_in"

# A Master handles configuration, slaves, incoming sources, logging and the admin interface

module.exports = class Master extends require("events").EventEmitter
    DefaultOptions:
        streams: {}
        max_zombie_life:    1000 * 60 * 60
    
    constructor: (opts) ->
        @options = _u.defaults opts||{}, @DefaultOptions
        
        @slaves = []
        @streams = {}
        @proxies = {}
        
        @listeners = slaves:{}, streams:{}, total:0
        
        # -- set up logging -- #
        
        @log = @options.logger
            
        # -- look for hard-coded configuration -- #

        if @options.streams?            
            process.nextTick =>
                @configureStreams @options.streams

        # -- load our streams configuration from redis -- #
        
        if @options.redis?
            _slaveUpdate = =>
                # pass config on to any connected slaves
                for sock in @slaves
                    sock.emit "streams", @config()
            
            @log.debug "initializing redis config"
            @redis = new Redis @options.redis
            @redis.on "config", (config) =>
                # stash the configuration
                @options = _u.defaults config||{}, @options

                # (re-)configure our master stream objects
                @configureStreams @options.streams
                
                _slaveUpdate()
            
            # save changed configuration to Redis        
            console.log "Registering config_update listener"
            @on "config_update", =>
                console.log "Redis got config_update: ", @config()
                @redis._update @config()
                
        # -- create a server to provide the admin -- #
        
        @admin = new Admin core:@, port:( @options.master?.port || @options.admin_port )
        
        # -- start the source listener -- #
            
        @sourcein = new SourceIn core:@, port:opts.source_port
            
        # -- set up the socket connection for slaves -- #
        
    #----------
    
    listenForSlaves: (server) ->
        # fire up a socket listener on our slave port
        @io = require("socket.io").listen server
        
        @_initIOProxies()
                    
        # FIXME: disconnect from our port on SIGTERM
        # process.on "SIGTERM", => @io.close()
        
        # add our authentication
        @io.configure =>
            # don't bombard us with stream data
            @io.disable "log"
            
            @io.set "authorization", (data,cb) =>
                @log.debug "In authorization for slave connection."
                # look for password                    
                if @options.master.password == data.query?.password
                    cb null, true
                else
                    cb "Invalid slave password.", false
        
        # look for slave connections    
        @io.on "connection", (sock) =>
            @log.debug "slave connection is #{sock.id}"
            
            if @options.streams
                # emit our configuration
                sock.emit "config", streams:@options.streams
                
            @slaves.push sock
            
            # attach event handler for log reporting
            socklogger = @log.child slave:sock.handshake.address.address
            sock.on "log", (obj = {}) => 
                socklogger[obj.level||'debug'].apply socklogger, [obj.msg||"",obj.meta||{}]
                
            # look for listener counts
            sock.on "listeners", (obj = {}) =>
                @_recordListeners sock.id, obj
            
        # attach disconnect handler
        @io.on "disconnect", (sock) =>
            @log.debug "slave disconnect from #{sock.id}"
            @slaves = _u(@slaves).without sock
            
    #----------
    
    config: ->
        config = streams:{}
        
        config.streams[k] = s.config() for k,s of @streams
        
        return config
    
    #----------
    
    _recordListeners: (slave,obj) ->
        @log.debug "slave #{slave} sent #{obj.total} listeners"
        @listeners.slaves[ slave ] = obj.total
        for k,c of obj.counts
            @streams[k]?.recordSlaveListeners slave, c
    
    # configureStreams can be called on a new core, or it can be called to 
    # reconfigure an existing core.  we need to support either one.
    configureStreams: (options) ->
        @log.debug "In configure with ", options

        # -- Sources -- #
        
        # are any of our current streams missing from the new options? if so, 
        # disconnect them
        for k,obj of @streams
            @log.debug "calling destroy on ", k
            obj.destroy() unless options?[k]
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
                
        @emit "streams", @streams
        
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
        @log.debug "updateStream called for ", key:stream.key, opts:opts
        
        # -- if they want to rename, the key must be unique -- #
        
        if stream.key != opts.key
            if @streams[ opts.key ]
                cb? "Stream key must be unique."
                return false
                
        # -- if we're good, ask the stream to configure -- #
        
        stream.configure opts, cb
        
    #----------
    
    streamsInfo: ->
        obj.status() for k,obj of @streams
    
    #----------
    
    _attachIOProxy: (stream) ->
        return false if !@io
        
        if @proxies[ stream.key ]
            return false
        
        # create a new proxy    
        @proxies[ stream.key ] = new Master.StreamProxy key:stream.key, stream:stream, master:@
        
        # and attach a listener to destroy it if the stream is removed
        stream.once "destroy", =>
            @proxies[ stream.key ]?.destroy()
    
    #----------
        
    class @StreamProxy extends require("events").EventEmitter
        constructor: (opts) ->
            @key = opts.key
            @stream = opts.stream
            @master = opts.master
                        
            @dataFunc = (chunk) => 
                for s in @master.slaves
                    s.emit "streamdata:#{@key}", chunk
                    
            @metaFunc = (chunk) =>
                for s in @master.slaves
                    s.emit "streammeta:#{@key}", chunk
            
            @stream.on "data", @dataFunc
            @stream.on "metadata", @metaFunc
            
        destroy: ->
            @stream.removeListener "data", @dataFunc
            @stream.removeListener "metadata", @dataFunc