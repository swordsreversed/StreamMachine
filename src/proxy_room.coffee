{EventEmitter}  = require "events"
Icecast = require("icecast-stack")
IcecastClient = require('icecast-stack/client')
_u = require('../lib/underscore')

module.exports = class ProxyRoom extends EventEmitter
    DefaultOptions:
        url:     ""
    
    #----------
    
    constructor: (options) ->
        @options = _u(_u({}).extend(@DefaultOptions)).extend( options || {} )
        @url = @options.url
        @connected = false
    
    #----------
        
    connect: (url) ->
        console.log "connecting to #{@url}"
        @stream = IcecastClient.createClient @url
        
        @stream.on "close", =>
            console.error "Connection closed to #{@url}"
            @connected = false
            
        @stream.on "data", (chunk) =>
            @emit "data", chunk

        @stream.on "metadata", (data) =>
            console.log "metadata is ", Icecast.parseMetadata(data)
            @emit "metadata", Icecast.parseMetadata(data)
    
        @connected = true
        
    #----------
        
        
