_u = require '../lib/underscore'
url = require('url')

module.exports = class SocketManager
    DefaultOptions:
        source:         null
        min_digits:     6
        
    constructor: (options) ->
        @options = _u(_u({}).extend(@DefaultOptions)).extend( options || {} )
            
        @io = require("socket.io").listen(@options.server)
        
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
            
            @sessions[sock.id] ||= 
                id:         sock.id
                socket:     sock
                listener:   null
                
            sock.emit "ready"
    
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

            headers = 
                "Content-Type":         "audio/mpeg"
                "Connection":           "close"
                "Transfer-Encoding":    "identity"

            # write out our headers
            res.writeHead 200, headers

            @dataFunc = (chunk) => 
                #console.log "chunk: ", chunk
                @res.write(chunk)

            # and register to sending data...
            @rewind.addListener @

            @req.connection.on "close", =>
                # stop listening to stream
                @rewind.removeListener @  
                
            # write up listener for offset event on socket
            session.socket?.on "offset", (i) =>
                @setOffset i

        #----------

        writeFrame: (chunk) ->
            @res.write chunk

        #----------

        setOffset: (offset) ->
            @_offset = @rewind.checkOffset offset
