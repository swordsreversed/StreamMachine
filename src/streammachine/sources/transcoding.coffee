_               = require "underscore"
FFmpeg          = require "fluent-ffmpeg"
PassThrough     = require("stream").PassThrough

module.exports = class TranscodingSource extends require("./base")
    TYPE: -> "Transcoding"

    constructor: (@opts) ->
        super skipParser:true

        @_queue = []

        @source = @opts.stream

        # we start up an ffmpeg transcoder and then listen for data events
        # from our source. Each time we get a chunk of audio data, we feed
        # it into ffmpeg.  We then run the stream of transcoded data that
        # comes back through our parser to re-chunk it. We count chunks to
        # attach the right timing information to the chunks that come out

        buf = new PassThrough
        @ffmpeg = new FFmpeg( source:buf ).addOptions @opts.ffmpeg_args.split("|")

        @ffmpeg.on "start", (cmd) =>
            console.log "ffmpeg started with ", cmd

        @ffmpeg.on "error", (err) =>
            console.log "ffmpeg err is ", err

        @ffmpeg.once "codecData", (data) =>
            #console.log "trans codec data is ", data

        @ffmpeg.writeToStream @parser

        # -- chunking -- #

        @chunker = new TranscodingSource.FrameChunker @emitDuration * 1000

        @parser.on "frame", (frame,header) =>
            # we need to re-apply our chunking logic to the output
            #console.log "trans p -> c"
            @chunker.write frame:frame, header:header

        @chunker.on "readable", =>
            while c = @chunker.read()
                #console.log "transcoding chunk read"
                o_c = @_queue.shift()
                c.ts = o_c.ts
                # re-attach the timestamp from the original data chunk
                @emit "data", c

        @source.on "data", (chunk) =>
            #console.log "trans s -> ff"
            @_queue.push chunk
            buf.write chunk.data

        # -- go ahead and emit vitals -- #

        process.nextTick =>
            @_setVitals
                emitDuration:   @emitDuration
                streamKey:      @opts.stream_key
