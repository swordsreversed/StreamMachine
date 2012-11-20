_u = require "underscore"

Rewind = require('../rewind_buffer')
Proxy = require('../sources/proxy_room')

# Master streams are about source management. 

module.exports = class Stream extends require('events').EventEmitter
    constructor: (@core,@key,@log,@opts)->
        @sources = []
        @source = null
        
        @emit_duration = 0
        
        @STATUS = "Initializing"
        
        # set up a rewind buffer
        @rewind = new Rewind @, @opts.rewind
        
        @metaFunc = (meta) => @emit "metadata", meta
        @dataFunc = (data) => @emit "data", data
        @headFunc = (head) => @emit "header", head
        
        # -- Hardcoded Source -- #
        
        # This is an initial source like a proxy that should be connected from 
        # our end, rather than waiting for an incoming connection
        
        if opts.source?
            console.log "Connecting initial source"
            newsource = new Proxy @, opts.source
            newsource.connect()
            @useSource newsource, (result) =>
                if result
                    @log.debug "Source connected."
                else
                    @log.error "Source connection failed."
                    
        # -- Listener Tracking -- #
        
        # We track listener counts from each slave. They get reported by 
        # the slave to the master, which then calls recordSlaveListeners 
        # to record them here.
        
        # We need to also get rid of old counts from a slave that goes 
        # offline, though, so we attach an interval function to remove 
        # numbers that haven't been updated in the last two minutes.
        
        @_listeners = {}
        
        setInterval =>
            now = Number(new Date)
            for s,c of @_listeners
                delete @_listeners[s] if now - (120 * 1000) > c.last_at||0
        , 60 * 1000

    #----------
    
    status: ->
        stream:     @key
        listeners:  @listeners()
        sources:    ( s.info() for s in @sources )
    
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
        
        # check whether this source should be made active. It should be if 
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
                old_source.removeListener "header",     @headFunc
                    
            @source = newsource
                    
            # connect to the new source's events
            newsource.on "metadata",   @metaFunc
            newsource.on "data",       @dataFunc
            newsource.on "header",     @headFunc
            
            # how often will we be emitting?
            @emit_duration = @source.emit_duration
                
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
        # there's not currently any configuration done here on the master side
        
    #----------
    
    listeners: ->
        total = 0
        total += c.count for s,c of @_listeners
        total
        
    listenersBySlave: ->
        @_listeners
    
    #----------
    
    recordSlaveListeners: (slave,count) ->
        if !@_listeners[slave]
            @_listeners[slave] = count:0, last_at:null
            
        @_listeners[slave].count = count
        @_listeners[slave].last_at = Number(new Date)
    
    #----------
        
    destroy: ->
        # shut down our sources and go away
        s.disconnect() for s in @sources
        true
        