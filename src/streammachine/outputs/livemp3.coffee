_u = require 'underscore'

module.exports = class LiveMP3
    constructor: (@stream,@req,@res) ->
        @id = null
        
        @reqIP      = req.connection.remoteAddress
        @reqPath    = req.url
        @reqUA      = _u.compact([req.param("ua"),req.headers?['user-agent']]).join(" | ")
        @offset     = @req.param("offset") || -1

        process.nextTick =>
            @res.chunkedEncoding = false
            @res.useChunkedEncodingByDefault = false
            
            headers = 
                "Content-Type":         "audio/mpeg"
            
            # write out our headers
            res.writeHead 200, headers
        
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
        
        
    #----------
    
    disconnect: (force=false) ->
        if force || @req.connection.destroyed
            @source?.disconnect()            
            @res?.end() unless (@res.stream?.connection?.destroyed || @res.connection?.destroyed)
    
    #----------
    
    connectToStream: ->
        unless @req.connection.destroyed
            @source = @stream.listen @, offset:@offset, pump:true
            @source.pipe @res
            