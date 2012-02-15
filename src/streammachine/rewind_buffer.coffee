_u = require 'underscore'

{EventEmitter}  = require "events"
http = require "http"
icecast = require("icecast-stack")
url = require('url')
fs = require('fs')

# RewindBuffer supports play from an arbitrary position in the last X hours 
# of our stream. We pass the incoming stream to the node-lame package to 
# split the audio into frames, then create a buffer of frames that listeners 
# can connect to.

module.exports = class RewindBuffer
    DefaultOptions:
        seconds:    (60*60*2)   # 2 hours
        burst:      30          # 30 seconds burst
    
    constructor: (source,options = {}) ->
        @options = _u(_u({}).extend(@DefaultOptions)).extend options
        
        @source = source
        
        # use the first header to compute some constants
        @source.once "header", (data,header) =>
            @framesPerSec   = @source.framesPerSec
            @max            = Math.round @framesPerSec * @options.seconds
            @burst          = Math.round @framesPerSec * @options.burst
        
            console.log "max buffer length is ", @max
        
        # each listener should be an object that defines obj._offset and 
        # obj.writeFrame. We implement RewindBuffer.Listener, but other 
        # classes can work with those pieces
        @listeners = []
        
        # create buffer as an array
        @buffer = []
                
        # headers and data get sent separately. we need to grab the header so 
        # we can lump it back together with the frame data later
        @lastHeader = null
        @source.on "header", (data,header) => @lastHeader = data
                    
        # frame listener will be used to fill our buffer with mp3 frames
        @source.on "frame", (frame) =>                
            # make sure we don't get a frame before header
            if @lastHeader
                # if we're at max length, shift off a frame (or more, if needed)
                while @buffer.length > @max
                    @buffer.shift()

                # take the new frame, add the header back in, and push it to the buffer
                buf = new Buffer( @lastHeader.length + frame.length )
                @lastHeader.copy(buf,0)
                frame.copy(buf,@lastHeader.length)
                @buffer.push buf

                # loop through all connected listeners and pass the frame buffer at 
                # their offset.
                bl = @buffer.length
                for l in @listeners
                    # we'll give them whatever is at length - offset
                    l.writeFrame @buffer[ bl - 1 - l._offset ]
                        
    #----------
    
    bufferedSecs: ->
        # convert buffer length to seconds
        Math.round @buffer.length / @framesPerSec 
        
    #----------
    
    checkOffset: (offset) ->
        # we're passed offset in seconds. we'll convert it to frames
        offset = Math.round Number(offset) * @framesPerSec
        
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
    
    pumpFrom: (offset,length) ->
        # we want to send _length_ frames, starting at _offset_
        
        # sanity checks...
        if offset > @buffer.length
            offset = @buffer.length
            
        length = Math.round(length*@framesPerSec)
        if length > offset
            length = offset
            
        bl = @buffer.length
        
        pumpLen = 0
        pumpLen += @buffer[ bl - 1 - (offset - i) ].length for i in [1..length]
        
        console.log "creating buffer of ", pumpLen, offset, length, bl
        
        pumpBuf = new Buffer pumpLen

        index = 0
        for i in [1..length]
            buf = @buffer[ bl - 1 - (offset - i) ]
            buf.copy pumpBuf, index, 0, buf.length
            index += buf.length
            
        return pumpBuf
        
    #----------
    
    burstFrom: (offset,obj) ->
        # we want to send them @burst frames (if available), starting at offset.
        # return them the new offset position
        
        bl = @buffer.length
        _u(if offset > @burst then @burst else offset).times (i) =>
            obj.writeFrame @buffer[ bl - 1 - (offset - i) ]
            
        if offset > @burst
            return offset - @burst
        else
            return 1
    
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