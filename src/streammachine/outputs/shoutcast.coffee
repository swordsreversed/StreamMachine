_u = require 'underscore'
icecast = require("icecast-stack")

module.exports = class Shoutcast
    constructor: (stream,req,res) ->
        @req = req
        @res = res
        @stream = stream
        
        @reqIP      = req.connection.remoteAddress
        @reqPath    = req.url
        @reqUA      = req.headers?['user-agent']
        
        @stream.log.debug "request is in Shoutcast output", stream:@stream.key
                
        # convert this into an icecast response
        @res = new icecast.IcecastWriteStack @res, @stream.options.meta_interval
        @res.queueMetadata StreamTitle:@stream.source.metaTitle, StreamUrl:@stream.source.metaURL
        
        headers = 
            "Content-Type":         "audio/mpeg"
            "Connection":           "close"
            "Transfer-Encoding":    "identity"
            "icy-name":             @stream.options.name
            "icy-metaint":          @stream.options.meta_interval
            
        # write out our headers
        res.writeHead 200, headers
        
        @metaFunc = (data) =>
            if data.StreamTitle
                @res.queueMetadata data

        @dataFunc = (chunk) => @res.write(chunk)
        
        # -- send a preroll if we have one -- #
        
        if @stream.preroll
            @stream.log.debug "making preroll request", stream:@stream.key
            @stream.preroll.pump @res, => @stream.registerListener @, metadata:@metaFunc, data:@dataFunc
        else
            @stream.registerListener @, metadata:@metaFunc, data:@dataFunc

        # -- what do we do when the connection is done? -- #
        
        @req.connection.on "close", => @stream.closeListener(@)