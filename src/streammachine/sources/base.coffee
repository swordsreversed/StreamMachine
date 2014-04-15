_u = require "underscore"
uuid = require "node-uuid"

module.exports = class Source extends require("events").EventEmitter

    #----------

    constructor: ->
        @uuid = @opts.uuid || uuid.v4()

        @isFallback = false
        @streamKey  = null
        @_vitals    = null

        @parser = new (require "../parsers/#{@opts.format}")

        @log = @opts.logger?.child uuid:@uuid

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
