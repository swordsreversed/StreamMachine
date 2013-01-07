_u = require "underscore"
Ice = require "ice-stack"

module.exports = class SourceIn extends require("events").EventEmitter
    constructor: (opts) ->
        @core = opts.core
        
        # grab our listening port
        @port = opts.port
        
        # create our server
        @server = new Ice.Server.createServer (req,res) => @_incoming(req,res)     
        @server.listen @port
    
    #----------
        
    _incoming: (req,res) ->
        headers = "X-Powered-By":"StreamMachine"
        
        # make sure the method is one we support...
        if req.method == "SOURCE"
            # source request... is the endpoint one that we recognize?
            if m = ///^\/(#{_u(@core.streams).keys().join("|")})///.exec req.path
                stream = @core.streams[ m[1] ]
                
                # cool, now make sure we have the headers we need
                
                # first, make sure the authorization header contains the right password
                if req.headers.authorization && @_authorize(stream,req.headers.authorization)
                    res.writeHead 200, headers
                    
                    # now create a new source
                    source = new (require "../sources/icecast") stream, req:req,res:res
                    stream.addSource source
                else
                    res.writeHead 401, headers
                    res.end "Invalid Source or Password."
                
            else
                res.writeHead 401, headers
                res.end "Invalid Source or Password."
        else
            res.writeHead 400, headers
            res.end "Invalid method #{res.method}."
    
    #----------
            
    _authorize: (stream,header) ->
        # split the auth type from the value
        [type,value] = header.split " "
        
        if type.toLowerCase() == "basic"
            value = new Buffer(value, 'base64').toString('ascii')
            [user,pass] = value.split ":"

            console.log "type/value is ", type, user, pass
            
            if pass == stream.opts.source_password
                true
            else
                false
        else
            false