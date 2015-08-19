_ = require "underscore"

module.exports = class SourceMount extends require("events").EventEmitter
    constructor: (@key,@log,opts) ->
        @sources = []
        @source = null

        @_vitals = null

        @log.event "Source Mount is initializing."

        @dataFunc = (data) =>
            @emit "data", data

        @vitalsFunc = (vitals) =>
            @_vitals = vitals
            @emit "vitals", vitals

    #----------

    status: ->
        s.info() for s in @sources

    #----------

    vitals: (cb) ->
        _vFunc = (v) =>
            cb? null, v

        if @_vitals
            _vFunc @_vitals
        else
            @once "vitals", _vFunc

    #----------

    addSource: (source,cb) ->
        # add a disconnect monitor
        source.once "disconnect", =>
            # remove it from the list
            @sources = _(@sources).without source

            # was this our current source?
            if @source == source
                # yes...  need to promote the next one (if there is one)
                if @sources.length > 0
                    @useSource @sources[0]
                    @emit "disconnect", active:true, count:@sources.length, source:@source
                else
                    @log.alert "Source disconnected. No sources remaining."
                    @_disconnectSource @source
                    @source = null
                    @emit "disconnect", active:true, count:0, source:null
            else
                # no... just remove it from the list
                @log.event "Inactive source disconnected."
                @emit "disconnect", active:false, count:@sources.length, source:@source

        # -- Add the source to our list -- #

        @sources.push source

        # -- Should this source be made active? -- #

        # check whether this source should be made active. It should be if
        # the active source is defined as a fallback

        if @sources[0] == source || @sources[0]?.isFallback
            # our new source should be promoted
            @log.event "Promoting new source to active.", source:(source.TYPE?() ? source.TYPE)
            @useSource source, cb

        else
            # add the source to the end of our list
            @log.event "Source connected.", source:(source.TYPE?() ? source.TYPE)

            # and emit our source event
            @emit "add_source", source

            cb? null

    #----------

    _disconnectSource: (source) ->
        #source.removeListener "metadata",   @sourceMetaFunc
        source.removeListener "data",       @dataFunc
        source.removeListener "vitals",     @vitalsFunc

    #----------

    useSource: (newsource,cb) ->
        # stash our existing source if we have one
        old_source = @source || null

        # set a five second timeout for the switchover
        alarm = setTimeout =>
            @log.error "useSource failed to get switchover within five seconds.",
                new_source: (newsource.TYPE?() ? newsource.TYPE)
                old_source: (old_source?.TYPE?() ? old_source?.TYPE)

            cb? new Error "Failed to switch."
        , 5000

        # Look for a header before switching
        newsource.vitals (err,vitals) =>
            if @source && old_source != @source
                # source changed while we were waiting for vitals. we'll
                # abort our change attempt
                @log.event "Source changed while waiting for vitals.",
                    new_source:     (newsource.TYPE?() ? newsource.TYPE)
                    old_source:     (old_source?.TYPE?() ? old_source?.TYPE)
                    current_source: (@source.TYPE?() ? @source.TYPE)

                return cb? new Error "Source changed while waiting for vitals."

            if old_source
                # unhook from the old source's events
                @_disconnectSource(old_source)

            @source = newsource

            # connect to the new source's events
            #newsource.on "metadata",   @sourceMetaFunc
            newsource.on "data",       @dataFunc
            newsource.on "vitals",     @vitalsFunc

            # how often will we be emitting?
            @emitDuration = vitals.emitDuration

            # note that we've got a new source
            process.nextTick =>
                @log.event "New source is active.",
                    new_source: (newsource.TYPE?() ? newsource.TYPE)
                    old_source: (old_source?.TYPE?() ? old_source?.TYPE)

                @emit "source", newsource
                @vitalsFunc vitals

            # jump our new source to the front of the list (and remove it from
            # anywhere else in the list)
            @sources = _.flatten [newsource,_(@sources).without newsource]

            # cancel our timeout
            clearTimeout alarm

            # give the a-ok to the callback
            cb? null

    #----------

    promoteSource: (uuid,cb) ->
        # do we have a source with this UUID?
        if ns = _(@sources).find( (s) => s.uuid == uuid )
            # we do...
            # make sure it isn't already the active source, though
            if ns == @sources[0]
                # it is.  nothing to be done.
                cb? null, msg:"Source is already active", uuid:uuid
            else
                # it isn't. we can try to promote it
                @useSource ns, (err) =>
                    if err
                        cb? err
                    else
                        cb? null, msg:"Promoted source to active.", uuid:uuid

        else
            cb? "Unable to find a source with that UUID on #{@key}"

    #----------

    dropSource: (uuid,cb) ->

    #----------

    disconnect: ->
        s.disconnect() for s in @sources
