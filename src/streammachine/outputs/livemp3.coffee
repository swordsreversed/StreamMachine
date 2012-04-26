_u = require 'underscore'

module.exports = class LiveMP3
    constructor: (stream,req,res) ->
        @req = req
        @res = res
        @stream = stream
        
        @reqIP      = req.connection.remoteAddress
        @reqPath    = req.url
        @reqUA      = req.headers?['user-agent']       
        
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
            @stream.preroll.pump @res, => @stream.registerListener @, data:@dataFunc
        else
            @stream.registerListener @, data:@dataFunc

        # -- what do we do when the connection is done? -- #
        
        @req.connection.on "close", => @stream.closeListener(@)
        