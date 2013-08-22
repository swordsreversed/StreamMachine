_u = require "underscore"
uuid = require "node-uuid"

module.exports = class Source extends require("events").EventEmitter
        
    #----------
    
    constructor: ->
        @uuid = uuid.v4() if !@uuid
        
        @isFallback = false
        @streamKey = null
        @_vitals = null
        
        @log = @stream.log.child uuid:@uuid
            
    #----------
    
    _new_parser: ->
        new (require "../parsers/#{@stream.opts.format}")
    
    #----------
        
    getStreamKey: (cb) ->
        if @streamKey
            cb? @streamKey
        else
            @once "vitals", => cb? @_vitals.streamKey
            
    #----------
    
    _setVitals: (vitals) ->
        @_vitals = vitals
        @emit "vitals", @_vitals
        
    vitals: (cb) ->
        if @_vitals
            cb? @_vitals
        else
            @once "vitals", => cb? @_vitals
        