_u = require '../lib/underscore'
{EventEmitter}  = require "events"
http = require "http"
icecast = require("icecast-stack")
lame = require("lame")
url = require('url')

fs = require('fs')

# RewindBuffer supports play from an arbitrary position in the last X hours 
# of our stream. We pass the incoming stream to the node-lame package to 
# split the audio into frames, then create a buffer of frames that listeners 
# can connect to.

module.exports = class RewindBuffer
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
            
            # loop through all connected listeners
            for l in @listeners
                # we'll give them whatever is at length - offset
                l.writeFrame @buffer[ bl - 1 - l._offset ]
                                                            
        @source.on "data", (chunk) => 
            @parser.write chunk
                        
    #----------
    
    bufferedSecs: ->
        # convert buffer length to seconds
        Math.round( @buffer.length / @framesPerSec )
    
    checkOffset: (offset) ->
        # we're passed offset in seconds. we'll convert it to frames
        offset = Math.round(Number(offset) * @framesPerSec)
        
        console.log "asked about offset of ", offset
        
        if offset < 0
            console.log "offset is invalid! 0 for live."
            return 0
                    
        if @buffer.length > offset
            console.log "Granted. current buffer length is ", @buffer.length
            return offset
        else
            console.log "Not available. Instead giving max buffer of ", @buffer.length - 1
            return @buffer.length - 1
    
    #----------
            
    addListener: (obj) ->
        console.log "addListener request"
        if obj._offset && obj._offset > 0 && obj.writeFrame
            @listeners.push obj
            return true
        else
            return false
    
    #----------
    
    removeListener: (obj) ->
        @listeners = _u(@listeners).without obj
        return true
        
    #----------
    
    class @Listener
        constructor: (req,res,rewind,offset) ->
            @req = req
            @res = res
            @rewind = rewind
            
            # set our internal offset to be invalid by default
            @_offset = -1
            
            # now set our offset using request and max buffer
            @setOffset offset       
            
            headers = 
                "Content-Type":         "audio/mpeg"
                "Connection":           "close"
                "Transfer-Encoding":    "identity"
                
            # write out our headers
            res.writeHead 200, headers
            
            # and register to sending data...
            @rewind.addListener @
                                
            @req.connection.on "close", =>
                # stop listening to stream
                @rewind.removeListener @  
        
        #----------
        
        writeFrame: (chunk) ->
            @res.write chunk
        
        #----------
                
        setOffset: (offset) ->
            @_offset = @rewind.checkOffset offset