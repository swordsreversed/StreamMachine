_ = require "underscore"

FileSource  = $src "sources/file"
TransSource = $src "sources/transcoding"

AAC         = $src "parsers/aac"

Logger          = $src "logger"

FILE_STREAM =
    key:                "test"
    source_password:    "abc123"
    root_route:         true
    seconds:            60*60*4
    format:             "mp3"

TRANS_MP3_STREAM =
    key:                "_test"
    source_password:    "abc123"
    root_route:         true
    seconds:            60*60*4
    format:             "mp3"
    stream_key:         "mp3-44100-64-s"
    ffmpeg_args:        "-c:a libmp3lame -b:a 64k"

TRANS_AAC_STREAM =
    key:                "_test"
    source_password:    "abc123"
    root_route:         true
    seconds:            60*60*4
    format:             "aac"
    stream_key:         "aac-44100-2-2"
    ffmpeg_args:        "-c:a libfdk_aac|-b:a 64k|-f:a adts"


in_file = $file "aac-256.aac"

describe "Transcoding Source", ->
    logger = new Logger {}

    file_source = null
    trans_source = null
    chunks = null

    before (done) ->
        file_source = new FileSource format:"aac", filePath:in_file
        file_source.once "_loaded", ->
            chunks = _.clone(file_source._chunks)
            done()

    before (done) ->
        trans_source = new TransSource
            stream:         file_source
            ffmpeg_args:    TRANS_AAC_STREAM.ffmpeg_args
            format:         "aac"
            stream_key:     "test"

        done()

    it "emits a chunk of data", (done) ->
        this.timeout(5000)
        trans_source.once "data", (chunk) ->
            console.log "chunk is ", chunk
            done()





