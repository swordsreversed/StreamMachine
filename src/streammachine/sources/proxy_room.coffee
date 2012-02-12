{EventEmitter}  = require "events"
Icecast = require("icecast-stack")
IcecastClient = require('icecast-stack/client')
_u = require('underscore')
Parser = require("../parsers/mp3")

module.exports = class ProxyRoom extends EventEmitter
    DefaultOptions:
        url:     ""
    
    #----------
    
    constructor: (key,options) ->
        @options = _u(_u({}).extend(@DefaultOptions)).extend( options || {} )
        @key            = key
        @url            = @options.url
        @connected      = false
        @framesPerSec   = null
        
        @metaTitle = null
        @metaURL = null
    
    #----------
        
    connect: (url) ->
        console.log "connecting to #{@url}"
        @stream = IcecastClient.createClient @url
        
        @stream.on "close", =>
            console.error "Connection closed to #{@url}"
            @connected = false
            
        @stream.on "data", (chunk) =>
            #console.log "#{@key} got data chunk"
            @emit "data", chunk

        @stream.on "metadata", (data) =>
            #console.log "#{@key} got metadata chunk"
            meta = Icecast.parseMetadata(data)
            @metaTitle = meta.StreamTitle
            @metaURL = meta.StreamUrl
            @emit "metadata", meta

        # attach mp3 parser for rewind buffer
        @parser = new Parser()
        @stream.on "data",      (chunk)     => @parser.write chunk
        @parser.on "frame",     (frame)     => @emit "frame", frame
        
        # we need to grab one frame to compute framesPerSec
        @parser.on "header", (data,header) =>
            if !@framesPerSec
                @framesPerSec = header.samplingRateHz / header.samplesPerFrame
                console.log "#{@key} setting framesPerSec to ", @framesPerSec
                
            @emit "header", data, header

        # return with success
        @connected = true
        
    #----------
        
        
