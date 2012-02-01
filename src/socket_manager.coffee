_u = require '../lib/underscore'
url = require('url')

module.exports = class SocketManager
    DefaultOptions:
        source:         null
        min_digits:     6
        
    constructor: (options) ->
        @options = _u(_u({}).extend(@DefaultOptions)).extend( options || {} )
            
        @io = require("socket.io").listen(@options.server)
        
        @rewind = @options.rewind
        
        @sessions = {}
        
        @io.configure =>
            @io.set "authorization", (data,cb) =>
                # get a session object.  pass in a key if provided
                #sess = @_findOrCreateSession data.query.session || data.rew_session
                
                # set our key in the session
                #data.rew_session = sess.key
                
                console.log "handshake data is ", data
                
                cb null, true
                
        @io.sockets.on "connection", (sock) =>
            console.log "connection is ", sock.id
            
            @sessions[sock.id] ||= {
                id:         sock.id
                socket:     sock
                listener:   null
            }
                
            sock.emit "ready",
                time:       new Date
                buffered:   @rewind.bufferedSecs()
        
        setInterval( =>
            @io.sockets.emit "timecheck"
                time:       new Date
                buffered:   @rewind.bufferedSecs()
        , 2000)
    
    #----------
            
    addListener: (req,res,rewind) ->
        requrl = url.parse(req.url,true)
        
        if requrl.query.socket? && sess = @sessions[requrl.query.socket]
            listen = new SocketManager.Listener sess,req,res,rewind
            sess.listener = listen
            console.log "wired listener to session #{sess.id}"

    #----------
        
    class @Listener
        constructor: (session,req,res,rewind) ->
            @req = req
            @res = res
            @rewind = rewind

            # set our internal offset to be live by default
            @_offset = 1
            @_playHead = 1
            
            console.log "req is ", req.headers
            
            headers = 
                "Content-Type":         "audio/mpeg"
                "Connection":           "keep-alive"
                "Transfer-Encoding":    "identity"
                "Content-Range":        "bytes 0-*/*"
                "Accept-Ranges":        "none"

            # write out our headers
            res.writeHead 200, headers

            # burst them the first two minutes if we have extra offset
            #@rewind.burst 120, (b) =>
            #    @res.write b
            
            # and register to sending data...
            @rewind.addListener @

            @req.connection.on "close", =>
                # stop listening to stream
                @rewind.removeListener @  
                
            # write up listener for offset event on socket
            session.socket?.on "offset", (i,fn) =>
                @setOffset i
                
                # send back the computed offset, in case we changed it
                if fn
                    fn(@_playHead / @rewind.framesPerSec)

        #----------

        writeFrame: (chunk) ->
            @res.write chunk

        #----------

        setOffset: (offset) ->
            @_playHead = @rewind.checkOffset offset
            @_offset = @rewind.burstFrom @_playHead, @
