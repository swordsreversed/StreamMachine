MasterMode = $src "modes/master"

STREAMS =
    mp3:
        key:                "test"
        source_password:    "abc123"
        root_route:         true
        seconds:            60*60*4
        format:             "mp3"


module.exports =
    STREAMS:    STREAMS

    startMaster: (stream,cb) ->
        s = STREAMS[stream]

        if !s
            cb new Error "Invalid stream spec"
            return false

        master_config =
            master:
                port:       0
                password:   "zxcasdqwe"
            source_port:    0
            log:
                stdout:     false
            streams: {}

        master_config.streams[ s.key ] = s

        new MasterMode master_config, (err,m) ->
            throw err if err

            info =
                master:         m
                master_port:    m.handle.address().port
                source_port:    m.master.sourcein.server.address().port
                stream_key:     s.key
                slave_uri:      ""
                config:         master_config

            info.slave_uri = "ws://127.0.0.1:#{info.master_port}?password=#{info.config.master.password}"

            cb null, info