Stream = require('stream').Stream
strtok = require('strtok')
parseFrame = require("lame/lib/parse").parseFrameHeader

module.exports = class MP3 extends Stream
    ID3V1_LENGTH = 128
    ID3V2_HEADER_LENGTH = 10
    MPEG_HEADER_LENGTH = 4
    
    FIRST_BYTE = new strtok.BufferType(1)
    
    MPEG_HEADER = new strtok.BufferType(MPEG_HEADER_LENGTH)
    REST_OF_ID3V2_HEADER = new strtok.BufferType(ID3V2_HEADER_LENGTH - MPEG_HEADER_LENGTH)
    REST_OF_ID3V1 = new strtok.BufferType(ID3V1_LENGTH - MPEG_HEADER_LENGTH)
    
    constructor: ->
        super
        @readable = @writable = true
        
        # set up status
        @frameSize = -1
        @beginning = true
        @gotFF = false
        @byteTwo = null
        @frameHeader = null
        
        strtok.parse @, (v,cb) =>
            # initial request...
            if v == undefined
                # we need to examine each byte until we get a FF
                return FIRST_BYTE
                
            # we're on-schedule now... we've had a valid frame.
            # buffer should be four bytes
            if @frameSize == -1 && @frameHeader
                tag = v.toString 'ascii', 0, 3
                
                if @beginning and tag == 'ID3'
                    # parse ID3 tag
                    console.log "got an ID3"
                    process.exit(1)
                    
                else if tag == 'TAG'
                    # parse ID3v2 tag
                    console.log "got a TAG"
                    process.exit(1)
                else
                    try
                        h = parseFrame(v)
                    catch e
                        # uh oh...  bad news
                        console.log "invalid header... ", v, tag
                        @frameHeader = null
                        return FIRST_BYTE
                
                    @frameHeader = h
                    @emit "header", v, h
                    @frameSize = @frameHeader.frameSize
                    
                    return new strtok.BufferType(@frameSize - MPEG_HEADER_LENGTH);
                
            if @gotFF and @byteTwo
                buf = new Buffer(4)
                buf[0] = 0xFF
                buf[1] = @byteTwo
                buf[2] = v[0]
                buf[3] = v[1]
                
                try
                    h = parseFrame(buf)
                catch e
                    # invalid header...  chuck everything and try again
                    @gotFF = false
                    @byteTwo = null
                    return FIRST_BYTE
                    
                # valid header...  we're on schedule now
                @gotFF = false
                @byteTwo = null                    
                @beginning = false
                
                @frameHeader = h
                @emit "header", buf, h
                @frameSize = @frameHeader.frameSize
                                    
                return new strtok.BufferType(@frameSize - MPEG_HEADER_LENGTH);
                
            if @gotFF
                if v[0]>>4 >= 0xE
                    @byteTwo = v[0]
                    
                    # need two more bytes
                    return new strtok.BufferType(2)
                else
                    @gotFF = false
                
            if @frameSize == -1 && !@gotFF                
                if v[0] == 0xFF
                    # possible start of frame header. need next byte to know more
                    @gotFF = true
                    return FIRST_BYTE
                else
                    # keep looking
                    return FIRST_BYTE
                    
            # if we get here we should have a frame
            @emit "frame", v
            
            @frameSize = -1
            return MPEG_HEADER
                
    
    write: (chunk) ->
        @emit "data", chunk
        true
    
    end: (chunk) ->
        if chunk
            @emit "data", chunk
            
        @emit "end"
        true