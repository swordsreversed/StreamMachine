_u      = require 'underscore'
icecast = require "icecast"

module.exports = class Shoutcast
    constructor: (@stream,@req,@res,@opts) ->
        @id = null
                        
        @reqIP      = req.connection.remoteAddress
        @reqPath    = req.url
        @reqUA      = _u.compact([req.param("ua"),req.headers?['user-agent']]).join(" | ")
        @offset     = @req.param("offset") || -1
        
        @stream.log.debug "request is in Shoutcast output", stream:@stream.key
        
        process.nextTick =>     
            @res.chunkedEncoding = false
            @res.useChunkedEncodingByDefault = false
            

            @ice = new icecast.Writer @stream.options.meta_interval            
            @ice.queue StreamTitle:@stream.StreamTitle, StreamUrl:@stream.StreamUrl
        
            headers = 
                "Content-Type":         "audio/mpeg"
                "icy-name":             @stream.StreamTitle
                "icy-url":              @stream.StreamUrl
                "icy-metaint":          @stream.options.meta_interval
                        
            # write out our headers
            res.writeHead 200, headers
                            
            @metaFunc = (data) =>
                @ice.queue data if data.StreamTitle

            @ice.pipe(@res)
                
            # -- send a preroll if we have one -- #
        
            if @stream.preroll && !@req.param("preskip")
                @stream.log.debug "making preroll request"
                @stream.preroll.pump @res, => @connectToStream()
            else
                @connectToStream()       
        
        # register our various means of disconnection
        @req.connection.on "end",   => @disconnect()
        @req.connection.on "close", => @disconnect()
        @res.connection.on "close", => @disconnect()
        
        @res.on "error", (err) =>
            console.log "got a response error for ", @id
        
        
    #----------
    
    disconnect: (force=false) ->
        if force || @req.connection.destroyed
            @source?.disconnect()            
            @res?.end() unless (@res.stream?.connection?.destroyed || @res.connection?.destroyed)
    
    #----------
    
    connectToStream: ->
        unless @req.connection.destroyed
            @source = @stream.listen @, offset:@offset, pump:true
            
            @source.pipe @ice
            @source.on "meta", @metaFunc
        
    #----------
            
