_       = require "underscore"
http    = require "http"
url     = require "url"
request = require "request"
xmldom  = require "xmldom"
xpath   = require "xpath"

debug = require("debug")("sm:slave:preroller")

module.exports = class Preroller
    constructor: (@stream,@key,@uri,@transcode_uri,cb) ->
        @_counter = 1

        # -- need to look at the stream to get characteristics -- #

        @stream.log.debug "Preroller calling getStreamKey"

        @stream.getStreamKey (@streamKey) =>
            @stream.log.debug "Preroller: Stream key is #{@streamKey}. Ready to start serving."

        cb? null, @

    #----------

    pump: (client,socket,writer,cb) ->
        cb = _.once(cb)
        aborted = false
        # short-circuit if we haven't gotten a stream key yet
        if !@streamKey || !@uri
            cb new Error("Preroll request before streamKey or missing URI.")
            return true

        # short-circuit if the socket has already disconnected
        if socket.destroyed
            cb new Error("Preroll request got destroyed socket.")
            return true

        count = @_counter++

        pdebug = (msg,args...) ->
            debug "#{count}: #{msg}", args...

        # If the preroll request can't be made in 5 seconds or less,
        # abort the preroll.
        # TODO: Make the timeout wait configurable
        prerollTimeout = setTimeout(=>
            @stream.log.debug "preroll request timeout. Aborting.", count
            pdebug "Hit timeout. Triggering abort."
            req.abort()
            aborted = true
            detach new Error("Preroll request timed out.")
        , 5*1000)

        # -- Set up our ad URI -- #

        uri = @uri
            .replace("!KEY!", @streamKey)
            .replace("!IP!", client.ip)
            .replace("!STREAM!", @key)
            .replace("!UA!", encodeURIComponent(client.ua))
            .replace("!UUID!", client.session_id)

        pdebug "Ad request URI is #{uri}"

        # -- make a request to the ad server -- #

        treq = null
        adreq = request.get uri, (err,res,body) =>
            if err
                perr = new Error "Ad request returned error: #{err}"
                @stream.log.error perr, error:err
                pdebug perr
                return detach perr

            if res.statusCode == 200
                new Preroller.AdObject body, (err,obj) =>
                    if err
                        perr = "Ad request was unsuccessful: #{err}"
                        @stream.log.debug perr
                        pdebug perr
                        return detach err

                    if obj.creativeURL
                        # we need to take the creative URL and pass it off
                        # to the transcoder
                        pdebug "Preparing transcoder request for #{obj.creativeURL} with key #{@streamKey}."

                        treq = request.get(@transcode_uri, qs:{ uri:obj.creativeURL, key:@streamKey })
                            .once "response", (resp) =>
                                pdebug "Transcoder response received: #{resp.statusCode}"

                                if resp.statusCode == 200
                                    treq.pipe(writer,end:false)
                                    treq.once "end", =>
                                        pdebug "Transcoder pipe complete."

                                        # we return by giving a function that should be called when the
                                        # impression criteria have been met
                                        detach null, =>
                                            if obj.impressionURL
                                                request.get obj.impressionURL, (err,resp,body) =>
                                                    if err
                                                        @stream.log.error "Failed to hit impression URL #{obj.impressionURL}: #{err}"
                                                    else
                                                        pdebug "Impression URL hit successfully."
                                            else
                                                @stream.log.debug "Session reached preroll impression criteria, but no impression URL present."
                                                pdebug "No impression URL found."
                                else
                                    err = new Error "Non-200 response from transcoder."
                                    pdebug err
                                    detach err
                            .once "error", (err) =>
                                pdebug "Transcoder request error: #{err}"
                                detach err

                    else
                        # no creative means just send the client on their way
                        detach()

            else
                perr = new Error "Ad request returned non-200 response: #{body}"
                @stream.log.debug perr
                pdebug perr
                return detach perr

        detach = _.once (err,impcb) =>
            pdebug "In detach"
            clearTimeout(prerollTimeout) if prerollTimeout
            socket.removeListener "close", conn_pre_abort
            socket.removeListener "end", conn_pre_abort
            cb err, impcb

        # attach a close listener to the response, to be fired if it gets
        # shut down and we should abort the request

        conn_pre_abort = =>
            detach()
            if socket.destroyed
                pdebug "Aborting"
                @stream.log.debug "aborting preroll ", count
                adreq?.abort()
                treq?.abort()
                aborted = true

        socket.once "close", conn_pre_abort
        socket.once "end", conn_pre_abort

    #----------

    class @AdObject
        constructor: (xmldoc,cb) ->
            @creativeURL    = null
            @impressionURL  = null

            @doc            = null

            debug "Parsing ad object XML"

            doc = new xmldom.DOMParser().parseFromString(xmldoc)

            debug "XML doc parsed."

            # -- VAST Support -- #

            if xpath.select("/VAST",doc)
                debug "VAST wrapper detected"

                if ad = xpath.select("VAST/Ad/InLine",doc)?[0]
                    debug "Ad document found."

                    # find our linear creative
                    if creative = xpath.select("./Creatives/Creative/Linear",ad)?[0]

                        # find the mpeg mediafile
                        if mediafile = xpath.select("string(./MediaFiles/MediaFile[@type='audio/mpeg']/text())",creative)
                            debug "Media File is #{mediafile}"
                            @creativeURL = mediafile

                    # find the impression URL
                    if impression = xpath.select("string(./Impression/text())",ad)
                        debug "Impression URL is #{impression}"
                        @impressionURL = impression

                    return cb null, @

                else
                    # VAST wrapper but no ad
                    return cb null, null

            cb new Error "Unsupported ad format"

