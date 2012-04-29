_u = require "underscore"
EventEmitter = require('events').EventEmitter

module.exports = class Stream extends EventEmitter
    DefaultOptions:
        meta_interval:  32768
        name:           ""
        
    constructor: (@core,key,log,opts) ->
        @options = _u.defaults opts||{}, @DefaultOptions
        
        # remove our max listener count
        @setMaxListeners 0
            
        @log = log
        @key = key
        
        @_id_increment = 1
        @_lmeta = {}
        
        @preroll = null
        @mlog_timer = null
        
        @dataFunc = (chunk) => (l.data(chunk) if l.data) for id,l of @_lmeta                    
        @metaFunc = (chunk) => (l.meta(chunk) if l.meta) for id,l of @_lmeta
        
        # now run configure...
        @configure(opts)
                                    
        # set up a rewind buffer
        @rewind = new @core.Rewind @, opts.rewind
            
    #----------
        
    configure: (opts) ->
        # -- Source -- #
        
        # make sure our source is valid
        if @core.Sources[ opts.source?.type ]
            # stash our existing source if we have one
            old_source = @source || null
            
            # bring the new / only source up
            source = new @core.Sources[ opts.source?.type ] @, @key, opts.source
            if source.connect()
                if old_source
                    # unhook from the old source's events
                    old_source.removeListener "metadata",   @metaFunc
                    old_source.removeListener "data",       @dataFunc
                    
                @source = source
                    
                # connect to the new source's events
                source.on "metadata",   @metaFunc
                source.on "data",       @dataFunc

                # disconnect the old source, which we're now no longer using
                old_source?.disconnect()
            else
                @log.error "Failed to connect to new source"
        else
            @log.error "Invalid source type.", opts:opts
            return false
                        
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
                        
    #----------
        
    disconnect: ->
        # handle clearing out lmeta
            
        # disconnect the stream source
        @source?.disconnect()
        
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