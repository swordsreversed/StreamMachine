_u = require "underscore"
Parser = require("../parsers/mp3")
Icecast = require("icecast-stack")

module.exports = class Icecast extends require("./base")
    DefaultOptions:
        foo: "bar"
        
    #----------
    
    TYPE: -> "Icecast ()"
    
    constructor: (@stream,options) ->
        @options = _u.defaults options||{}, @DefaultOptions
        
        super()
        
        @req = @options.req
        @res = @options.res
        
        @log = @stream.log
        
        @emit_duration  = 0.5
    
        # data is going to start streaming in as data on req. We need to pipe 
        # it into a parser to turn it into frames, headers, etc
        
        @parser = new Parser()
        
        @_chunk_queue = []
        @_chunk_queue_ts = null
        
        @last_header = null
        
        console.log "req is ", @req
                
        # incoming -> Parser
        @req.on "data", (chunk) => @parser.write chunk
            
        # outgoing -> Stream
        @parser.on "frame", (frame) =>
            @emit "frame", frame

            # -- queue up frames until we get to @emit_duration -- #
            if @last_header
                # -- recombine frame and header -- #
                
                fbuf = new Buffer( @last_header.length + frame.length )
                @last_header.copy(fbuf,0)
                frame.copy(fbuf,@last_header.length)
                @_chunk_queue.push fbuf
                
                if !@_chunk_queue_ts
                    @_chunk_queue_ts = (new Date)
                
                if @framesPerSec && ( @_chunk_queue.length / @framesPerSec > @emit_duration )
                    len = 0
                    len += b.length for b in @_chunk_queue
                
                    # make this into one buffer
                    buf = new Buffer(len)
                    pos = 0
                
                    for fb in @_chunk_queue
                        fb.copy(buf,pos)
                        pos += fb.length
                        
                    buf_ts = @_chunk_queue_ts
                    
                    # reset chunk array
                    @_chunk_queue.length = 0
                    @_chunk_queue_ts = (new Date)
                
                    # emit new buffer
                    @log.debug "emit with #{buf.length}"
                    @emit "data", buf
                    #@emit "data", { data:buf, ts:buf_ts }
        
        # we need to grab one frame to compute framesPerSec
        @parser.on "header", (data,header) =>
            if !@framesPerSec || !@stream_key
                # -- compute frames per second -- #
                
                @framesPerSec = header.samplingRateHz / header.samplesPerFrame
                @log.debug "setting framesPerSec to ", frames:@framesPerSec
                @log.debug "first header is ", header
                
                # -- compute stream key -- #
                
                @stream_key = ['mp3',header.samplingRateHz,header.bitrateKBPS,(if header.modeName == "Stereo" then "s" else "m")].join("-")
                
            @last_header = data
            @emit "header", data, header
            
        @req.on "end", =>
            @log.debug "Icecast source got end event"
            # source has gone away
            @emit "disconnect"
            @res.end()

        # return with success
        @connected = true
    
    #----------
    
    info: ->
        console.log "ice res is ", @res
        
        source:     @TYPE?() ? @TYPE
        connected:  @connected
        url:        "INVALID" #[@req.connection.remoteAddress,@req.connection.remotePort].join(":")
        stream_key: @stream_key
        uuid:       @uuid
    
    #----------
    
    disconnect: ->
        @res.end()
        @connected = false
        @emit "disconnect"