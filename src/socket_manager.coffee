_u = require '../lib/underscore'

module.exports = class SocketManager
    DefaultOptions:
        source:         null
        min_digits:     6
        
    constructor: (options) ->
        @options = _u(_u({}).extend(@DefaultOptions)).extend( options || {} )
            
        @io = require("socket.io").listen(@options.server)
        
        sessions = {}
        
        @io.configure =>
            @io.set "authorization", (data,cb) =>
                # get a session object.  pass in a key if provided
                #sess = @_findOrCreateSession data.query.session || data.rew_session
                
                # set our key in the session
                #data.rew_session = sess.key
                
                console.log "handshake data is ", data
                
                cb null, true
                
        @io.sockets.on "connection", (sock) =>
            console.log "connection is ", sock
            
            sock.emit "ready"

