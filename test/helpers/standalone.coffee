StandaloneMode = $src "modes/standalone"

uuid    = require "node-uuid"
_       = require "underscore"

STREAMS =
    mp3:
        key:                "test"
        source_password:    "abc123"
        root_route:         true
        seconds:            60*60*4
        format:             "mp3"

module.exports =
    STREAMS:    STREAMS

    startStandalone: (stream,cb) ->
        s = STREAMS[stream]

        if stream && !s
            cb new Error "Invalid stream spec"
            return false

        config =
            chunk_duration: 0.25
            port:           0
            source_port:    0
            log:
                stdout:     false
            streams: {}

        sconfig = null

        if stream
            # generate a random stream key
            streamkey = uuid.v4()

            sconfig = config.streams[ streamkey ] = _.extend {}, s, key:streamkey

        new StandaloneMode config, (err,sa) ->
            throw err if err

            info =
                standalone:         sa
                port:               sa.handle?.address().port
                source_port:        sa.master.sourcein.server.address().port
                stream_key:         sconfig?.key
                source_password:    sconfig?.source_password
                slave_uri:          ""
                config:             config

            info.api_uri    = "http://127.0.0.1:#{info.port}/api"

            cb null, info
