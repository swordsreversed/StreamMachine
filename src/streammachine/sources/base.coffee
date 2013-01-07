_u = require "underscore"

module.exports = class Source extends require("events").EventEmitter
        
    #----------
    
    constructor: ->
        @uuid = null
        @stream_key = null
    
    #----------
    
    setUUID: (uuid) ->
        @uuid = uuid
    
    #----------
        
    get_stream_key: (cb) ->
        if @stream_key
            cb? @stream_key
        else
            @once "header", => cb? @stream_key