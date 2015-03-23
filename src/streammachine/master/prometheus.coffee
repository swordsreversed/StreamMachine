Prometheus  = require "prometheus-client"

module.exports = class PrometheusMaster
    constructor: (@master) ->
        @client = new Prometheus namespace:"streammachine", subsystem:"master"

        # -- Register our Metrics -- #

        @connected_sources = @client.newGauge
            name: "stream_sources"
            help: "Number of sources connected for this stream."

        @client.register(@connected_sources)

        @source_latency = @client.newGauge
            name: "stream_source_latency"
            help: "How many milliseconds is the source chunk ts behind our clock time?"

        @client.register(@source_latency)

        # -- Set our source loop -- #

        @_sourceInt = setInterval =>
            _process = (stream,idx,source) =>
                latency =
                    if source.last_ts
                        Number(new Date()) - Number(source.last_ts)
                    else
                        -1

                @source_latency.set stream:stream, index:idx, latency

            for k,stream of @master.streams
                _process(stream.key,idx,source) for source,idx in stream.sources
                @connected_sources.set stream:stream.key, stream.sources.length

            for k,sg of @master.stream_groups
                _process(sg._stream.key,idx,source) for source,idx in sg._stream.sources
                @connected_sources.set stream:sg._stream.key, sg._stream.sources.length

        , 1000

        # -- Attach metrics to the API -- #

        # FIXME: This should probably happen in the API class...
        console.log "Attaching prometheus routing for /metrics"
        @master.api.app.get "/metrics", (req,res) =>
            console.log "METRICS REQUEST"
            @client.metricsFunc req,res