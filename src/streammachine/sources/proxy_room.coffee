{EventEmitter}  = require "events"
Icecast = require("icecast-stack")
IcecastClient = require('icecast-stack/client')
_u = require('underscore')
Parser = require("../parsers/mp3")

module.exports = class ProxyRoom extends EventEmitter
    DefaultOptions:
        url:     ""
        
    #----------
    
    constructor: (stream,key,options) ->
        @options = _u(_u({}).extend(@DefaultOptions)).extend( options || {} )
        @key            = key
        @stream         = stream
        @url            = @options.url
        @connected      = false
        @framesPerSec   = null
        
        @log = @stream.log
        
        @setMaxListeners 0
        
        @metaTitle = @options.metaTitle || null
        @metaURL = @options.metaURL || null
    
    #----------
        
    connect: (url) ->
        @log.debug "connecting to #{@url}"
        @stream = IcecastClient.createClient @url, "user-agent":"StreamMachine 0.1.0"
        
        @stream.on "close", =>
            @log.debug "Connection closed to #{@url}"
            @connected = false
            
        @stream.on "data", (chunk) =>
            #console.log "#{@key} got data chunk"
            @emit "data", chunk

        @stream.on "metadata", (data) =>
            meta = Icecast.parseMetadata(data)
            
            if meta.StreamTitle
                @metaTitle = meta.StreamTitle
            
            if meta.StreamUrl
                @metaURL = meta.StreamUrl
                
            @emit "metadata", StreamTitle:@metaTitle, StreamUrl:@metaURL

        # attach mp3 parser for rewind buffer
        @parser = new Parser()
        @stream.on "data",      (chunk)     => @parser.write chunk
        @parser.on "frame",     (frame)     => @emit "frame", frame
        
        # we need to grab one frame to compute framesPerSec
        @parser.on "header", (data,header) =>
            if !@framesPerSec || !@stream_key
                # -- compute frames per second -- #
                
                @framesPerSec = header.samplingRateHz / header.samplesPerFrame
                @log.debug "#{@key} setting framesPerSec to ", @framesPerSec
                @log.debug "#{@key} first header is ", header
                
                # -- compute stream key -- #
                
                @stream_key = ['mp3',header.samplingRateHz,header.bitrateKBPS,(if header.modeName == "Stereo" then "s" else "m")].join("-")
                
            @emit "header", data, header

        # return with success
        @connected = true
        
    #----------
        
    disconnect: ->
        console.log "FIXME: Need to handle disconnect in source"
        
    #----------
        
    get_stream_key: (cb) ->
        if @stream_key
            cb? @stream_key
        else
            @once "header", => cb? @stream_key