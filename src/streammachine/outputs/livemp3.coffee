_u = require 'underscore'

module.exports = class LiveMP3
    constructor: (@stream,@req,@res) ->
        @id = null
        
        @reqIP      = req.connection.remoteAddress
        @reqPath    = req.url
        @reqUA      = req.headers?['user-agent']       

        process.nextTick =>
            headers = 
                "Content-Type":         "audio/mpeg"
                "Connection":           "close"
                "Transfer-Encoding":    "identity"
            
            # write out our headers
            res.writeHead 200, headers
        
            @dataFunc = (chunk) => @res.write(chunk)
                                    
            # -- send a preroll if we have one -- #
        
            if @stream.preroll
                @stream.log.debug "making preroll request", stream:@stream.key
                @stream.preroll.pump @res, => @connectToStream()
            else
                @connectToStream()
            
        @req.connection.on "close", => @closeStream()
        
    #----------
    
    connectToStream: ->
        unless @req.connection.destroyed
            # -- register our listener -- #
            @id = @stream.registerListener @, data:@dataFunc
        
    #----------
    
    closeStream: ->
        @stream.closeListener @id if @id
        
