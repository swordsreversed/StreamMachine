_u = require 'underscore'
icecast = require("icecast-stack")

module.exports = class Shoutcast
    constructor: (@stream,@req,@res) ->
        @id = null
                
        @reqIP      = req.connection.remoteAddress
        @reqPath    = req.url
        @reqUA      = _u.compact([req.param("ua"),req.headers?['user-agent']]).join(" | ")
        
        @stream.log.debug "request is in Shoutcast output", stream:@stream.key
        
        process.nextTick =>     
            @res.chunkedEncoding = false
            @res.useChunkedEncodingByDefault = false
            
            # convert this into an icecast response
            @res = new icecast.IcecastWriteStack @res, @stream.options.meta_interval
            @res.queueMetadata StreamTitle:@stream.metaTitle, StreamUrl:@stream.metaURL
        
            headers = 
                "Content-Type":         "audio/mpeg"
                "icy-name":             @stream.options.name
                "icy-metaint":          @stream.options.meta_interval
                        
            # write out our headers
            res.writeHead 200, headers
                            
            @metaFunc = (data) =>
                if data.StreamTitle
                    @res.queueMetadata data

            @dataFunc = (chunk) => @res.write(chunk)
                
            # -- send a preroll if we have one -- #
        
            if @stream.preroll && !@req.param("preskip")
                @stream.log.debug "making preroll request", stream:@stream.key
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
            if @id
                @stream.closeListener @id
                @id = null
            
            @res?.end() unless (@res.stream?.connection?.destroyed || @res.connection?.destroyed)
    
    #----------
    
    connectToStream: ->
        unless @req.connection.destroyed
            # -- pump 30 seconds from the rewind buffer -- #
            @res.write @stream.rewind.pumpSeconds(30)||(new Buffer(0)) if @stream.rewind
        
            # -- register our listener -- #
            @id = @stream.registerListener @, data:@dataFunc, meta:@metaFunc
        
    #----------
            
