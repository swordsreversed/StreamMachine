Icecast = require 'icecast'
_u      = require 'underscore'

util    = require 'util'
url     = require 'url'

domain  = require "domain"

module.exports = class ProxyRoom extends require("./base")
    TYPE: -> "Proxy (#{@url})"

    # opts should include:
    # format:   Format for Parser (aac or mp3)
    # url:      URL for original stream
    # fallback: Should we set the isFallback flag? (default false)
    # logger:   Logger (optional)
    constructor: (@opts) ->
        super()

        @isFallback     = @opts.fallback || false

        @connected      = false
        @framesPerSec   = null

        @_in_disconnect = false

        @_chunk_queue = []
        @_chunk_queue_ts = null

        # connection drop handling
        # (FIXME: bouncing not yet implemented)
        @_maxBounces    = 10
        @_bounces       = 0
        @_bounceInt     = 5

        @StreamTitle    = null
        @StreamUrl      = null

        @d = domain.create()

        @d.on "error", (err) =>
            nice_err = "ProxyRoom encountered an error."

            nice_err = switch err.syscall
                when "getaddrinfo"
                    "Unable to look up DNS for Icecast proxy."
                else
                    "Error making connection to Icecast proxy."

            @emit "error", nice_err, err

        @d.run =>
            @connect()

    #----------

    info: ->
        source:     @TYPE?() ? @TYPE
        connected:  @connected
        url:        @url
        streamKey: @streamKey
        uuid:       @uuid
        isFallback: @isFallback

    #----------

    connect: ->
        @log?.debug "connecting to #{@url}"

        # attach mp3 parser for rewind buffer
        @parser = @_new_parser()

        url_opts = url.parse @url
        url_opts.headers = "user-agent":"StreamMachine 0.1.0"

        Icecast.get url_opts, (ice) =>
            @icecast = ice

            @icecast.on "close", =>
                console.log "proxy got close event"
                unless @_in_disconnect
                    setTimeout ( => @connect() ), 5000

                    @log?.debug "Lost connection to #{@url}. Retrying in 5 seconds"
                    @connected = false

            @icecast.on "metadata", (data) =>
                unless @_in_disconnect
                    meta = Icecast.parse(data)
                    console.log "metadata is ", meta

                    if meta.StreamTitle
                        @StreamTitle = meta.StreamTitle

                    if meta.StreamUrl
                        @StreamUrl = meta.StreamUrl

                    @emit "metadata", StreamTitle:@StreamTitle||"", StreamUrl:@StreamUrl||""

            # incoming -> Parser
            @icecast.on "data", (chunk) => @parser.write chunk

            # return with success
            @connected = true

            @emit "connect"

        # outgoing -> Stream
        @on "_chunk", (frame) =>
            @emit "data", chunk

    #----------

    disconnect: ->
        @_in_disconnect = true

        @icecast.removeAllListeners()
        @parser.removeAllListeners()
        @removeAllListeners()

        @icecast.end()

        @parser = null
        @icecast = null

        console.log "Shut down proxy source using #{@url}"
