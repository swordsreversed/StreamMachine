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
                @emit "config", @options.streams
                @configureStreams @options.streams

        # -- load our streams configuration from redis -- #
        
        if @options.redis?
            @log.debug "initializing redis config"
            @redis = new Redis @options.redis
            @redis.on "config", (streams) =>
                # stash the configuration
                @options.streams = streams
            
                @emit "config", streams

                # (re-)configure our master stream objects
                @configureStreams streams
                
                # and then pass it on to any connected slaves
                for sock in @slaves
                    sock.emit "config", streams:streams
                
        # -- create a server to provide the admin -- #
        
        @server = new Admin core:@, port:( @options.master?.port || @options.admin_port )
        
        # -- start the source listener -- #
            
        @sourcein = new SourceIn core:@, port:opts.source_port
            
        # -- set up the socket connection for slaves -- #
            
        if @options.master?.port && @options.master?.password
            @log.debug "Master listening to port ", port:@options.master.port
            # fire up a socket listener on our slave port
            @io = require("socket.io").listen @server?.server || @options.master.port
            
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
            @streams.delete k
        
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
                @streams[key] = new Stream @, key, @log.child(stream:key), opts 
                
        @_initIOProxies()
                
        @emit "streams", @streams
        
    #----------
    
    streamsInfo: ->
        obj.status() for k,obj of @streams
    
    #----------
    
    _initIOProxies: ->
        return false if !@io
        
        # any to add?
        for k,obj of @streams
            @proxies[k] = new Master.StreamProxy key:k, stream:obj, master:@
            
        # any to remove?
        for k,obj of @proxies
            @proxies[k].destroy if !@streams[k]
        
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