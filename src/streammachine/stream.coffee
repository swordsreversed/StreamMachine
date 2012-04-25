_u = require "underscore"
EventEmitter = require('events').EventEmitter

module.exports = class Stream extends EventEmitter
    DefaultOptions:
        meta_interval:  32768
        name:           ""
        
    constructor: (@core,key,log,opts) ->
        @options = _u.defaults opts||{}, @DefaultOptions
            
        @log = log
        @key = key
            
        @listeners = []

        @preroll = null
        @mlog_timer = null
        
        @dataFunc = (chunk) => @emit "data", chunk
        @metaFunc = (chunk) => @emit "metadata", chunk
        
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
                for l in @listeners
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
        # disconnect any listeners
        @closeListener(l) for l in @listeners
            
        # disconnect the stream source
        @source?.disconnect()
        
    #----------
            
    registerListener: (listen,handlers={}) ->
        # increment our listener count
        @listeners.push obj:listen, handlers:handlers , startTime:(new Date), minuteTime:(new Date)

        # register handlers
        @on evt, func for evt,func of handlers
        
        # log the connection start
        @log.debug "Connection start", req:listen.req, listeners:@listeners.length
        
        true
        
    #----------
            
    closeListener: (listen) ->
        # find listener in our listener array
        lmeta = _u(@listeners).detect (obj) => obj.obj == listen
        
        if lmeta
            # unregister listener handlers
            @removeListener evt, func for evt,func of lmeta.handlers
            
            # remove from our listeners array
            @listeners = _u(@listeners).without lmeta
        
            # compute listening duration
            seconds = null
            endTime = (new Date)
            seconds = (endTime.getTime() - lmeta.startTime.getTime()) / 1000
                    
            # log the connection end
            @log.debug "Connection end", req:listen.req, listeners:@listeners.length, bytes:listen.req?.connection?.bytesWritten, seconds:seconds
            @log.request "", path:listen.reqPath, ip:listen.reqIP, bytes:listen.req?.connection?.bytesWritten, seconds:seconds, time:endTime, ua:listen.reqUA
            
            true
        else
            @log.error "Failed to remove listener from stream", req:listen.req
            false