_u = require 'underscore'
{EventEmitter}  = require "events"
icecast = require("icecast-stack")

module.exports = class Caster extends EventEmitter
    class @Shoutcast
        constructor: (req,res,stream) ->
            @req = req
            @res = res
            @stream = stream
            
            console.log "registered shoutcast client"
            
            # convert this into an icecast response
            @res = new icecast.IcecastWriteStack @res, @stream.meta_interval
            @res.queueMetadata StreamTitle:@stream.source.metaTitle, StreamURL:@stream.source.metaUrl
            
            headers = 
                "Content-Type":         "audio/mpeg"
                "Connection":           "close"
                "Transfer-Encoding":    "identity"
                "icy-name":             @stream.name
                "icy-metaint":          @stream.meta_interval
                
            # register ourself as a listener
            #@stream.registerListener(@)
            
            # write out our headers
            res.writeHead 200, headers
            
            @metaFunc = (data) =>
                if data.StreamTitle
                    @res.queueMetadata data

            @dataFunc = (chunk) => @res.write(chunk)
            
            @stream.source.on "metadata",   @metaFunc
            @stream.source.on "data",       @dataFunc
                                
            @req.connection.on "close", =>
                # stop listening to stream
                @stream.source.removeListener "data", @dataFunc
                
                # and to metadata
                @stream.source.removeListener "metadata", @metaFunc
                
                # tell the caster we're done
                #@stream.closeListener(@)
            
    #----------        
            
    class @LiveMP3
        constructor: (req,res,stream) ->
            @req = req
            @res = res
            @stream = stream                
            
            headers = 
                "Content-Type":         "audio/mpeg"
                "Connection":           "close"
                "Transfer-Encoding":    "identity"
                
            # register ourself as a listener
            #@stream.registerListener(@)
            
            # write out our headers
            res.writeHead 200, headers
            
            @dataFunc = (chunk) => @res.write(chunk)

            # and start sending data...
            @stream.source.on "data", @dataFunc
                                
            @req.connection.on "close", =>
                # stop listening to stream
                @stream.source.removeListener "data", @dataFunc
                
                # tell the caster we're done
                #@stream.closeListener(@)
                
    #----------
        
