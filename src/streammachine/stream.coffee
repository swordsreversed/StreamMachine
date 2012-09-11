_u = require "underscore"

# Streams are the endpoints that listeners connect to. A stream has many listeners 
# and can have one or more sources, though only one is active at once. Other sources 
# are kept active as backups and can be used for failover should the original 
# source disconnect.
#
# In the initial config, the stream can also specify a fallback source that will be 
# used only when no other source is connected.  

module.exports = class Stream extends require('events').EventEmitter
    DefaultOptions:
        meta_interval:  32768
        max_buffer:     4194304 # 4 megabits (64 seconds of 64k audio)
        name:           ""
        
    constructor: (@core,@key,@log,opts) ->
        @options = _u.defaults opts||{}, @DefaultOptions
        
        @STATUS = "Initializing"
        
        # remove our max listener count
        @setMaxListeners 0
            
        @_id_increment = 1
        @_lmeta = {}
        
        @sources = []
        
        @preroll = null
        @mlog_timer = null

        @dataFunc = (chunk) => (l.data(chunk) if l.data) for id,l of @_lmeta                    
        @metaFunc = (chunk) => (l.meta(chunk) if l.meta) for id,l of @_lmeta
        
        # now run configure...
        process.nextTick => @configure(opts)
                                    
        # set up a rewind buffer
        @rewind = new @core.Rewind @, opts.rewind        
            
    #----------
    
    info: ->
        key:        @key
        status:     @STATUS
        sources:    []
        listeners:  @countListeners()
        options:    @options
        
    #----------
    
    addSource: (source,cb) ->
        # add a disconnect monitor
        source.once "disconnect", =>
            # was this our current source?
            if @sources[0] == source
                # yes...  need to promote the next one (if there is one)
                if @sources.length > 1
                    @sources = _u(@sources).without @source
                    @useSource @sources[0]
                else
                    @log.debug "Source disconnected. None remaining."
            else
                # no... just remove it from the list
                @sources = _u(@sources).without @source
        
        # check whether this source should be made active. If should be if 
        # the active source is defined as a fallback
        
        if @sources[0]?.options.fallback || !@sources[0]
            # go to the front
            @log.debug "Promoting new source to replace fallback."
            @useSource source, cb
        else
            # add the source to the end of our list
            @log.debug "Sticking new source on the end of the list."
            @sources.push source
        
            # and emit our source event
            @emit "add_source", source
            
            cb?()
            
    #----------

    useSource: (newsource,cb=null) ->
        # stash our existing source if we have one
        old_source = @source || null

        # set a five second timeout for the switchover
        alarm = setTimeout =>
            @log.debug "Failed to get source switchover in five seconds"
            cb?(false)
        , 5000
        
        # Look for a header before switching
        newsource.once "header", =>
            if old_source
                # unhook from the old source's events
                old_source.removeListener "metadata",   @metaFunc
                old_source.removeListener "data",       @dataFunc
                    
            @source = newsource
                    
            # connect to the new source's events
            newsource.on "metadata",   @metaFunc
            newsource.on "data",       @dataFunc
                
            # note that we've got a new source
            process.nextTick =>
                console.log "emit source event"
                @emit "source", newsource

            # jump our new source to the front of the list (and remove it from
            # anywhere else in the list)
            @sources = _u.flatten [newsource,_u(@sources).without newsource]
            
            # cancel our timeout
            clearTimeout alarm
            
            # give the a-ok to the callback
            cb?(true)

    #----------
    
    configure: (opts) ->
        # -- Preroll -- #
        
        @log.debug "Preroll settings are ", preroll:opts.preroll
        
        @preroll.disconnect() if @preroll
        
        if opts.preroll?
            # create a Preroller connection
            @preroll = new @core.Preroller @, @key, opts.preroll
        
        # -- Should we be logging minutes? -- #
        
        if opts.log_minutes && !@mlog_timer
            # set up a timer to log minutes listened
            @mlog_timer = setInterval => 
                # run through each listener and log minute or time listened
                now = new Date
                for id,l of @_lmeta
                    # we only log requests that have lasted more than one minute. 
                    # we use startTime for the length the session has been going, 
                    # but use minuteTime for accumulating unlogged time 
                    if ( now.getTime() / 1000 - l.startTime.getTime() / 1000 ) > 60
                        dur = ( now.getTime() / 1000 - l.minuteTime.getTime() / 1000 )
                        @log.minute "", path:l.obj.reqPath, time:now, ua:l.obj.reqUA, duration:dur
                        l.minuteTime = now
                                        
            , 60*1000
            
        else if @mlog_timer && !opts.log_minutes
            clearInterval @mlog_timer
            @mlog_timer = null
            
        # -- Set up bufferSize poller -- #
        
        # We disconnect clients that have fallen too far behind on their 
        # buffers. Buffer size can be configured via the "max_buffer" setting, 
        # which takes bits
        console.log "max buffer size is ", @options.max_buffer
        @buf_timer = setInterval =>
            all_buf = 0
            for id,l of @_lmeta
                conn = l.obj.req?.socket
                
                all_buf += conn?.bufferSize||0
                
                if (conn?.bufferSize||0) > @options.max_buffer
                    @log.debug "Connection exceeded max buffer size.", req:l.obj.req, bufferSize:conn.bufferSize
                    l.obj.disconnect(true)

            @log.debug "All buffers: #{all_buf}"
        , 60*1000
        
        # -- Hardcoded Source -- #
        
        # This is an initial source like a proxy that should be connected from 
        # our end, rather than waiting for an incoming connection
        
        if opts.source?
            console.log "Connecting initial source"
            newsource = new @core.Sources[ opts.source.type ] @, opts.source
            newsource.connect()
            @useSource newsource, (result) =>
                if result
                    @log.debug "Source connected."
                else
                    @log.error "Source connection failed."
                        
    #----------
        
    disconnect: ->
        # handle clearing out lmeta
        l.obj.disconnect(true) for k,l of @_lmeta
            
        # disconnect any stream sources
        s.disconnect() for s in @sources
        
    #----------
    
    countListeners: ->
        _u(@_lmeta).keys().length
        
    #----------
            
    registerListener: (listen,handlers) ->
        # generate a metadata hash
        lmeta = 
            id:         @_id_increment++
            obj:        listen
            startTime:  (new Date) 
            minuteTime: (new Date)
            
        for k in ['data','meta']
            lmeta[ k ] = handlers[ k ] if handlers[ k ]
            
        # stash it...
        @_lmeta[ lmeta.id ] = lmeta
            
        console.log "in registerListener for ", lmeta.id
        debugger;
            
        # log the connection start
        @log.debug "Connection start", req:listen.req, listeners:_u(@_lmeta).keys().length
                
        # return the id
        lmeta.id
        
    #----------
            
    closeListener: (id) ->
        console.log "in closeListener for ", id
        
        lmeta = @_lmeta[id]
        
        if lmeta
            # -- remove from listeners -- #
            delete @_lmeta[id]
            
            # -- log the request's end -- #
            
            # compute listening duration
            seconds = null
            endTime = (new Date)
            seconds = (endTime.getTime() - lmeta.startTime.getTime()) / 1000
                    
            # log the connection end
            @log.debug "Connection end", id:id, req:lmeta.obj.req, listeners:_u(@_lmeta).keys().length, bytes:lmeta.obj.req?.connection?.bytesWritten, seconds:seconds
        
            @log.request "", 
                path:       lmeta.obj.reqPath
                ip:         lmeta.obj.reqIP
                bytes:      lmeta.obj.req?.connection?.bytesWritten
                seconds:    seconds
                time:       endTime
                ua:         lmeta.obj.reqUA
        
            true
        else
            console.log "Unable to find metadata for request ", id