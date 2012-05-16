_u = require 'underscore'

module.exports = class LiveMP3
    constructor: (@stream,@req,@res) ->
        @id = null
        
        @reqIP      = req.connection.remoteAddress
        @reqPath    = req.url
        @reqUA      = req.headers?['user-agent']       

        process.nextTick =>
            @res.chunkedEncoding = false
            @res.useChunkedEncodingByDefault = false
            
            headers = 
                "Content-Type":         "audio/mpeg"
            
            # write out our headers
            res.writeHead 200, headers
        
            @dataFunc = (chunk) => @res.write(chunk)
                                    
            # -- send a preroll if we have one -- #
        
            if @stream.preroll
                @stream.log.debug "making preroll request", stream:@stream.key
                @stream.preroll.pump @res, => @connectToStream()
            else
                @connectToStream()
            
        # register our various means of disconnection
        @req.connection.on "end",   => @disconnect()
        @req.connection.on "close", => @disconnect()
        @res.connection.on "close", => @disconnect()
        
        
    #----------
    
    connectToStream: ->
        unless @req.connection.destroyed
            # -- pump 30 seconds from the rewind buffer -- #
            @res.write @stream.rewind.pumpSeconds(30) if @stream.rewind
        
            # -- register our listener -- #
            @id = @stream.registerListener @, data:@dataFunc
        
    #----------
    
    disconnect: (force=false) ->
        if force || @req.connection.destroyed
            if @id
                @stream.closeListener @id 
                @id = null
            
            @res?.end() unless (@res.stream?.connection?.destroyed || @res.connection?.destroyed)