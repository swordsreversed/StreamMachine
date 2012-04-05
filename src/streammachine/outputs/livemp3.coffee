_u = require 'underscore'

module.exports = class LiveMP3
    constructor: (stream,req,res) ->
        @req = req
        @res = res
        @stream = stream                
        
        headers = 
            "Content-Type":         "audio/mpeg"
            "Connection":           "close"
            "Transfer-Encoding":    "identity"
            
        # register ourself as a listener
        @stream.registerListener(@)
        
        # write out our headers
        res.writeHead 200, headers
        
        @dataFunc = (chunk) => @res.write(chunk)

        # and start sending data...
        @stream.source.on "data", @dataFunc
                            
        @req.connection.on "close", =>
            # stop listening to stream
            @stream.source.removeListener "data", @dataFunc
            
            # tell the caster we're done
            @stream.closeListener(@)