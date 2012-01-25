_u = require '../lib/underscore'
{EventEmitter}  = require "events"
http = require "http"
icecast = require("icecast-stack")
lame = require("lame")
url = require('url')

fs = require('fs')

module.exports = class Caster extends EventEmitter
    DefaultOptions:
        source:         null
        port:           8080
        meta_interval:  10000
        name:           "Caster"
        title:          "Welcome to Caster"
        max_buffer:     (39 * 60 * 5)
    
    #----------
    
    constructor: (options) ->
        @options = _u(_u({}).extend(@DefaultOptions)).extend( options || {} )

        if !@options.source
            console.error "No source for broadcast!"
            
        # attach to source
        @source = @options.source
        
        # create the rewind buffer
        @rewind = new Caster.RewindBuffer(@)
        
        # listener count
        @listeners = 0
                    
        # set up shoutcast listener
        @server = http.createServer (req,res) => @_handle(req,res)
        @server.listen(@options.port)
        console.log "caster is listening on port #{@options.port}"
        
        # for debugging information
        #@source.on "data", (chunk) =>
        #    console.log "Listeners: #{@listeners}"
        
    #----------
    
    registerListener: (obj) ->
        @listeners += 1
        
    #----------
    
    closeListener: (obj) ->
        @listeners -= 1
    
    #----------
            
    _handle: (req,res) ->
        console.log "in _handle for caster request"
        
        # -- parse request to see what we're giving back -- #
                
        requrl = url.parse(req.url,true)
        
        if requrl.pathname == "/stream.mp3"
            console.log "Asked for stream.mp3"
            
            icyMeta = if req.headers['icy-metadata'] == 1 then true else false

            if icyMeta
                # -- create a shoutcast broadcaster instance -- #
                new Caster.Shoutcast(req,res,@)
                
            else
                # -- create a straight mp3 listener -- #
                console.log "no icy-metadata requested...  straight mp3"
                new Caster.LiveMP3(req,res,@)
                
        else if requrl.pathname == "/rewind.mp3"
            offset = Number(requrl.query.off) || 1
            
            if offset < 1
                offset = 1
                
            new Caster.RewindMP3(req,res,@,offset)
        
        else if requrl.pathname == "/listen.pls"
            # -- return shoutcast playlist -- #
            res.writeHead 200, 
                "Content-Type": "audio/x-scpls"
                "Connection":   "close"
            
            res.end( 
                """
                [playlist]
                NumberOfEntries=1
                File1=http://localhost:#{@options.port}/stream.mp3
                """   
            )             
        else
            res.write "Nope..."
    
    #----------            
            
    class @Shoutcast
        constructor: (req,res,caster) ->
            @req = req
            @res = res
            @caster = caster
            
            console.log "registered shoutcast client"
            
            # convert this into an icecast response
            @res = new icecast.IcecastWriteStack @res, @caster.options.meta_interval
            res.queueMetadata StreamTitle:"Welcome to Caster", StreamURL:""
            
            headers = 
                "Content-Type":         "audio/mpeg"
                "Connection":           "close"
                "Transfer-Encoding":    "identity"
                "icy-name":             @caster.options.name
                "icy-metaint":          @caster.options.meta_interval
                
            # register ourself as a listener
            @caster.registerListener(@)
            
            # write out our headers
            res.writeHead 200, headers
            
            @metaFunc = (data) =>
                if data.streamTitle
                    @res.queueMetadata data
                    
            @caster.source.on "metadata", @metaFunc      
            
            @dataFunc = (chunk) => @res.write(chunk)

            # and start sending data...
            @caster.source.on "data", @dataFunc
                                
            @req.connection.on "close", =>
                # stop listening to stream
                @caster.source.removeListener "data", @dataFunc
                
                # and to metadata
                @caster.source.removeListener "metadata", @metaFunc
                
                # tell the caster we're done
                @caster.closeListener(@)
            
            
    #----------        
            
    class @LiveMP3
        constructor: (req,res,caster) ->
            @req = req
            @res = res
            @caster = caster                
            
            headers = 
                "Content-Type":         "audio/mpeg"
                "Connection":           "close"
                "Transfer-Encoding":    "identity"
                
            # register ourself as a listener
            @caster.registerListener(@)
            
            # write out our headers
            res.writeHead 200, headers
            
            @dataFunc = (chunk) => @res.write(chunk)

            # and start sending data...
            @caster.source.on "data", @dataFunc
                                
            @req.connection.on "close", =>
                # stop listening to stream
                @caster.source.removeListener "data", @dataFunc
                
                # tell the caster we're done
                @caster.closeListener(@)
                
    #----------
    
    class @RewindMP3
        constructor: (req,res,caster,offset) ->
            @req = req
            @res = res
            @caster = caster                
            
            headers = 
                "Content-Type":         "audio/mpeg"
                "Connection":           "close"
                "Transfer-Encoding":    "identity"
                
            # register ourself as a listener
            #@caster.registerListener(@)
            
            # write out our headers
            res.writeHead 200, headers
            
            @dataFunc = (chunk) => 
                #console.log "chunk: ", chunk
                @res.write(chunk)

            # and register to sending data...
            @caster.rewind.addListener @dataFunc, offset
                                
            @req.connection.on "close", =>
                # stop listening to stream
                @caster.rewind.removeListener @dataFunc
                
                # tell the caster we're done
                #@caster.closeListener(@)
            
    #----------
    
    # RewindBuffer supports play from an arbitrary position in the last X hours 
    # of our stream. We pass the incoming stream to the node-lame package to 
    # split the audio into frames, then create a buffer of frames that listeners 
    # can connect to.
    
    class @RewindBuffer
        constructor: (caster) ->
            @caster = caster
            @source = @caster.source
            
            @max = @caster.options.max_buffer
            
            console.log "max buffer length is ", @max
            
            # each element should be [obj,offset]
            @listeners = []
            
            # create buffer as an array
            @buffer = []
            
            @parser = lame.createParser()
            
            # grab header from our first frame for computations. our stream is 
            # assumed to be a fixed bit rate.
            
            @lastHeader = null
            
            @parser.on "header", (data,header) =>
                if !@header
                    @header = header
                    @framesPerSec = header.samplingRateHz / header.samplesPerFrame
                    
                #console.log "header is ", header
                    
                @lastHeader = data
                        
            # frame listener will be used to fill our buffer with cleanly split mp3 frames
                
            @parser.on "frame", (frame) =>                
                while @buffer.length > @max
                    @buffer.shift()

                # make sure we don't get a frame before header
                if @lastHeader
                    buf = new Buffer( @lastHeader.length + frame.length )
                    @lastHeader.copy(buf,0)
                    frame.copy(buf,@lastHeader.length)
                    @buffer.push buf

                bl = @buffer.length
                
                for l in @listeners
                    # we'll give them whatever is at length - offset
                    # l[0] is our callback, l[1] is our offset
                    l[0] @buffer[ bl - l[1] ]
                                                                
            @source.on "data", (chunk) => 
                @parser.write chunk
                            
        #----------
                
        addListener: (callback,offset) ->
            # we're passed offset in seconds. we'll convert it to frames
            offset = Math.round(offset * @framesPerSec)
            
            console.log "frames per sec is ", @framesPerSec
            console.log "adding a listener with offset of ", offset
                        
            if @buffer.length > offset
                console.log "Granted. current buffer length is ", @buffer.length
                @listeners.push [ callback, offset ]
                return offset
            else
                console.log "Not available. Instead giving max buffer of ", @buffer.length
                @listeners.push [ callback, @buffer.length ]
                return @buffer.length
        
        #----------
        
        removeListener: (callback) ->
            @listeners = _u(@listeners).reject (v) -> v[0] == callback
            return true
            