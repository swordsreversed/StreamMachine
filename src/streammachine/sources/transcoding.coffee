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

        @_buf = new PassThrough
        @ffmpeg = new FFmpeg( source:@_buf ).addOptions @opts.ffmpeg_args.split("|")

        @ffmpeg.on "start", (cmd) =>
            @log?.info "ffmpeg started with #{ cmd }"

        @ffmpeg.on "error", (err) =>
            @log?.error "ffmpeg transcoding error: #{ err }"
            # FIXME: What do we do to restart the transcoder?

        @ffmpeg.writeToStream @parser

        # -- chunking -- #

        @source.once "data", (first_chunk) =>
            @emit "connected"

            @chunker = new TranscodingSource.FrameChunker @emitDuration * 1000, first_chunk.ts

            @parser.on "frame", (frame,header) =>
                # we need to re-apply our chunking logic to the output
                @chunker.write frame:frame, header:header

            @chunker.on "readable", =>
                while c = @chunker.read()
                    @emit "data", c

            @source.on "data", (chunk) =>
                @_buf.write chunk.data

            @_buf.write first_chunk.data

        # -- go ahead and emit vitals -- #

        process.nextTick =>
            @_setVitals
                emitDuration:   @emitDuration
                streamKey:      @opts.stream_key
