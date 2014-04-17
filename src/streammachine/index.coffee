_u      = require "underscore"
url     = require 'url'
http    = require "http"
nconf   = require "nconf"



module.exports = class StreamMachine
    @StandaloneMode: require "./modes/standalone"
    @MasterMode:     require "./modes/master"
    @SlaveMode:      require "./modes/slave"

    @Defaults:
        mode:           "standalone"
        handoff_type:   "external"
        port:           8000
        source_port:    8001
        log:
            stdout:     true

        ua_skip:        false
        live_streaming:
            segment_duration:   10

