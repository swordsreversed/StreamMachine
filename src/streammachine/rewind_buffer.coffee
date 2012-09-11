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
    
    constructor: (stream,options = {}) ->
        @options = _u.defaults options||{}, @DefaultOptions
        
        @stream = stream
        
        @secsPerChunk = Infinity
        @max = null
        @burst = null
                        
        # each listener should be an object that defines obj._offset and 
        # obj.writeFrame. We implement RewindBuffer.Listener, but other 
        # classes can work with those pieces
        @listeners = []
        
        # create buffer as an array
        @buffer = []
        
        @source = null
        
        # -- set up header and frame functions -- #
        
        @dataFunc = (chunk) =>
            # if we're at max length, shift off a chunk (or more, if needed)
            while @buffer.length > @max
                @buffer.shift()

            # push the chunk on the buffer
            @buffer.push chunk

            # loop through all connected listeners and pass the frame buffer at 
            # their offset.
            bl = @buffer.length
            for l in @listeners
                # we'll give them whatever is at length - offset
                l.writeFrame @buffer[ bl - 1 - l._offset ]
        
        # -- look for stream connections -- #
                
        @stream.on "source", (newsource) =>
            @stream.log.debug "RewindBuffer got source event"
            # -- disconnect from old source -- #
            
            @source.removeListener "data", @dataFunc if @source
            
            console.log "removed data listener"
            
            # -- compute initial stats -- #
                        
            newsource.once "header", (data,header) =>
                console.log "in rewind once header listener", @secsPerChunk, newsource.emit_duration
                if @secsPerChunk && @secsPerChunk == newsource.emit_duration
                    # reconnecting, but rate matches so we can keep using 
                    # our existing buffer.
                    @stream.log.debug "Rewind buffer validated new source.  Reusing buffer."
                
                else
                    if @secsPerChunk
                        # we're reconnecting, but didn't match rate...  we 
                        # should wipe out the old buffer
                        @buffer = []
                        
                    # compute new frame numbers
                    @secsPerChunk   = newsource.emit_duration
                    @max            = Math.round @options.seconds / @secsPerChunk
                    @burst          = Math.round @options.burst / @secsPerChunk
        
                    console.log "Rewind's max buffer length is ", @max
                
                # connect our data listener
                newsource.on "data", @dataFunc
                    
                # keep track of our source
                @source = newsource

    #----------
    
    bufferedSecs: ->
        # convert buffer length to seconds
        Math.round @buffer.length / @secsPerChunk 
        
    #----------
    
    checkOffset: (offset) ->
        # we're passed offset in seconds. we'll convert it to frames
        offset = Math.round Number(offset) / @secsPerChunk
        
        console.log "asked about offset of ", offset
        
        if offset < 0
            console.log "offset is invalid! 0 for live."
            return 0
                    
        if @buffer.length >= offset
            console.log "Granted. current buffer length is ", @buffer.length
            return offset
        else
            console.log "Not available. Instead giving max buffer of ", @buffer.length - 1
            return @buffer.length - 1
            
    #----------
    
    pumpSeconds: (seconds) ->
        # pump the most recent X seconds
        
        frames = @checkOffset seconds
            
        @pumpFrom(frames,frames)
        
    #----------
    
    pumpFrom: (offset,length) ->
        # we want to send _length_ frames, starting at _offset_
        
        return null if offset == 0
        
        # sanity checks...
        if offset > @buffer.length
            offset = @buffer.length
            
        length = Math.round(length/@secsPerChunk)
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
            
            @res.chunkedEncoding = false
            @res.useChunkedEncodingByDefault = false
            
            # set our internal offset to be invalid by default
            @_offset = -1
            
            # now set our offset using request and max buffer
            @setOffset offset       
            
            headers = 
                "Content-Type":         "audio/mpeg"
                "Connection":           "close"
                
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