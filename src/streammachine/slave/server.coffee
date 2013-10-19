express = require "express"
_u = require("underscore")
util = require 'util'
fs = require 'fs'
path = require 'path'

module.exports = class Server extends require('events').EventEmitter
    DefaultOptions:
        core:           null
        slave_mode:     false
        mount_admin:    true
    
    constructor: (opts) ->
        @opts = _u.defaults opts||{}, @DefaultOptions
        
        @core = @opts.core
        @logger = @opts.logger
        
        # -- socket server -- #
        
        @sockets = new Server.Sockets @, @logger.child(mode:"sockets")
        
        # -- set up our express app -- #
        
        @app = express()
        @app.httpAllowHalfOpen = true
        @app.useChunkedEncodingByDefault = false
        
        # -- Stream Finder -- #
        
        @app.param "stream", (req,res,next,key) =>
            # make sure it's a valid stream key
            if key? && s = @core.streams[ key ]
                req.stream = s
                next()
            else
                res.status(404).end "Invalid stream.\n"
                                    
        #@server.use (req,res,next) => @streamRouter(req,res,next)
        
        # -- Funky URL Rewriters -- #
        
        @app.use (req,res,next) =>
            if @core.root_route
                if req.url == '/' || req.url == "/;stream.nsv" || req.url == "/;"
                    req.url = "/#{@core.root_route}"
                    next()
                else if req.url == "/listen.pls"
                    console.log "Converting /listen.pls to /#{@core.root_route}.pls"
                    req.url = "/#{@core.root_route}.pls"
                    next()
                else
                    next()
            else
                next()
        
        # -- Utility Routes -- #
        
        @app.get "/index.html", (req,res) =>
            res.set "content-type", "text/html"
            res.set "connection", "close"
            
            res.status(200).end """
                <html>
                    <head><title>StreamMachine</title></head>
                    <body>
                        <h1>OK</h1>
                    </body>
                </html>
            """
                    
        @app.get "/crossdomain.xml", (req,res) =>
            res.set "content-type", "text/xml"
            res.set "connection", "close"
            
            res.status(200).end """
                <?xml version="1.0"?>
                <!DOCTYPE cross-domain-policy SYSTEM "http://www.macromedia.com/xml/dtds/cross-domain-policy.dtd">
                <cross-domain-policy>
                <allow-access-from domain="*" />
                </cross-domain-policy>
            """
        # -- Stream Routes -- #
        
        # playlist file
        @app.get "/:stream.pls", (req,res) =>
            console.log "Sending playlist."
            res.set "X-Powered-By", "StreamMachine"
            res.set "content-type", "audio/x-scpls"
            res.set "connection", "close"

            host = req.headers?.host || req.stream.options.host
        
            res.status(200).end "[playlist]\nNumberOfEntries=1\nFile1=http://#{host}/#{req.stream.key}/\n"
        
        # head request    
        @app.head "/:stream", (req,res) =>
            res.set "content-type", "audio/mpeg"            
            res.status(200).end()

        # listen to the stream
        @app.get "/:stream", (req,res) =>
            res.set "X-Powered-By", "StreamMachine"
            
            # -- Stream match! -- #
        
            if req.param("socket")
                # socket listener
                @sockets.registerListener req.param("socket"), req.stream, req:req, res:res
                
            else if req.param("pump")
                # pump listener pushes from the buffer as fast as possible
                new @core.Outputs.pumper req.stream, req:req, res:res
                
            else
                # normal live stream (with or without shoutcast)
                if req.headers['icy-metadata']
                    # -- shoutcast listener -- #
                    new @core.Outputs.shoutcast req.stream, req:req, res:res
                else
                    # -- straight mp3 listener -- #
                    new @core.Outputs.raw req.stream, req:req, res:res
    
    #----------
    
    listen: (port,cb) ->
        console.log "Start listening"
        @hserver = @app.listen port, =>
            @io = require("socket.io").listen @hserver
            @emit "io_connected", @io
            cb?(@hserver)
        @hserver
        
    #----------
        
    close: ->
        console.log "stopListening"
        @hserver?.close => console.log "listening stopped."
        
    #----------
    
    class @Sockets extends require("events").EventEmitter
        constructor: (@server,@logger) ->
            @sessions = {}
            
            @server.on "io_connected", (@io) =>
                @logger.debug "Got IO_connected event."
                @_configureStreams @server.core.streams
                
                @server.core.on "streams", (streams) => @_configureStreams(streams)
        
        #----------
        
        registerListener: (sock_id,stream,opts) ->
            # make sure it's a valid socket
            if sock = @sessions[ sock_id ]
                if sock.stream == stream
                    # good to go...
                    sock.listener = new @server.core.Outputs.raw stream, opts
                    @logger.debug "Got socket listener for #{ sock_id }"
                else
                    
            else
        
        #----------
                
        _configureStreams: (streams) ->
            @_listen(k,s) for k,s of streams
            
        _listen: (key,stream) ->
            @logger.debug "Registering listener on /#{key}"
            @io.of("/#{key}").on "connection", (sock) =>
                console.log "connection is ", sock.id
                console.log "stream is #{key}"
        
                @sessions[sock.id] ||= {
                    id:         sock.id
                    stream:     stream
                    socket:     sock
                    listener:   null
                    offset:     1
                }
        
                sess = @sessions[sock.id]
                
                # send ready signal
                sock.emit "ready",
                    time:       new Date
                    buffered:   stream.bufferedSecs()
                    
                @sessions[sock.id].timecheck = setInterval =>
                    sock.emit "timecheck",
                        time:       new Date
                        buffered:   stream.bufferedSecs()
                , 5000
                
                # -- Handle offset requests -- #
                
                # add offset listener
                sock.on "offset", (i,fn) =>
                    @logger.debug "Offset request with #{i}"
                    
                    # this might be called with a stream connection active, 
                    # or it might not.  we have to check
                    if sess.listener
                        playHead = sess.listener.source.setOffset(i)
                        sess.offset = playHead
                    else
                        # just set it on the socket.  we'll use it when they connect
                        sess.offset = sess.stream.checkOffset i
                
                    secs = sess.offset / sess.stream._rsecsPerChunk
                    @logger.debug offset:sess.offset, "Offset by #{secs} seconds"
                    
                    fn? secs
                
                # -- Handle disconnect -- #
                
                sock.on "disconnect", =>
                    console.log "disconnected socket."
                    clearInterval @sessions[sock.id].timecheck
                    delete @sessions[sock.id]
    
        