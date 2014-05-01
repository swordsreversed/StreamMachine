_ = require "underscore"

module.exports = class BaseOutput
    constructor: (output) ->
        # turn @opts into @client

        @client = output:output
        @socket = null

        if @opts.req && @opts.res
            # -- startup mode...  sending headers -- #

            @client.ip          = @opts.req.connection.remoteAddress
            @client.path        = @opts.req.url
            @client.ua          = _.compact([@opts.req.param("ua"),@opts.req.headers?['user-agent']]).join(" | ")
            @client.user_id     = @opts.req.user_id
            @client.session_id  = @opts.req.param("session")

            @socket = @opts.req.connection

        else
            @client = @opts.client
            @socket = @opts.socket