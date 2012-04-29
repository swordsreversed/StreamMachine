_u = require("underscore")
url = require('url')
http = require "http"
express = require "express"
Logger = require "./log_controller"

module.exports = class Core
    DefaultOptions:
        foo:        null
        streams:    {}
        
    Redis:  require "./redis_config"
    Stream: require "./stream"
    Rewind: require "./rewind_buffer"
    Preroller: require "./preroller"
        
    Sources:
        proxy:  require("./sources/proxy_room")
        
    Outputs:
        pumper:     require("./outputs/pumper")
        shoutcast:  require("./outputs/shoutcast")
        mp3:        require("./outputs/livemp3")
        sockets:    require("./outputs/sockets")
        
    #----------
        
    constructor: ->        
        @streams = {}
        
        @root_route = null
                
    #----------
        
    # configureStreams can be called on a new core, or it can be called to 
    # reconfigure an existing core.  we need to support either one.
    configureStreams: (options) ->
        console.log "In configure with ", options

        # -- Sources -- #
        
        # are any of our current streams missing from the new options? if so, 
        # disconnect them
        for k,obj in @streams
            obj.disconnect() unless options.streams?[k]
            @streams.delete k
        
        # run through the streams we've been passed, initializing sources and 
        # creating rewind buffers
        for key,opts of options.streams
            console.log "stream for #{key}"
            if @streams[key]
                # existing stream...  pass it updated configuration
                @log.debug opts:opts, "Passing updated config to source: #{key}"
                @streams[key].configure opts
            else
                @log.debug opts:opts, "Starting up source: #{key}"
                @streams[key] = new @Stream @, key, @log.child(stream:key), opts
                
            # should this stream accept requests to /?
            if opts.root_route
                @root_route = key
                        
    #----------
    
    streamRouter: (req,res,next) ->
        res.removeHeader("X-Powered-By");
        
        # -- default routes -- #
                
        # default URL (and also a mapping for weird stream.nsv route)
        if @root_route && (req.url == '/' || req.url == "/;stream.nsv")
            # pretend the request came in on the default stream
            req.url = "/#{@root_route}"
            
        # default playlist
        if @root_route && req.url == "/listen.pls"
            req.url = "/#{@root_route}.pls"
            
        # -- utility routes -- #
        
        # index.html
        if req.url == "/index.html"
            res.writeHead 200,
                "content-type": "text/html"
                "connection": "close"
            
            res.end """
                    <html>
                        <head><title>StreamMachine</title></head>
                        <body>
                            <h1>OK</h1>
                        </body>
                    </html>
                    """
            
            return true
            
        # crossdomain.xml
        if req.url == "/crossdomain.xml"
            res.writeHead 200, 
                "content-type": "text/xml"
                "connection": "close"
                
            res.end """
                    <?xml version="1.0"?>
                    <!DOCTYPE cross-domain-policy SYSTEM "http://www.macromedia.com/xml/dtds/cross-domain-policy.dtd">
                    <cross-domain-policy>
                    <allow-access-from domain="*" />
                    </cross-domain-policy>
                    """
            
            return true
            
        # -- Stream Routing -- #
        
        # does the request match one of our streams?
        if m = ///^\/(#{_u(@streams).keys().join("|")})(?:\.(mp3|pls))?/?$///.exec req.url     
            res.header("X-Powered-By","StreamMachine")
            
            console.log "match is ", m[1]
            stream = @streams[ m[1] ]
            
            # fend off any HEAD requests
            if req.method == "HEAD"
                res.writeHead 200, 
                    "content-type": "audio/mpeg"
                    "connection":   "close"
                    
                res.end()
                return true
            
            # -- Handle playlist request -- #
                
            console.log "format is ", m[2]
            
            if m[2] && m[2] == "pls"
                host = req.headers?.host || stream.options.host
                
                res.writeHead 200,
                    "content-type": "audio/x-scpls"
                    "connection":   "close"
                                        
                res.end("[playlist]\nNumberOfEntries=1\nFile1=http://#{host}/#{stream.key}/\n")
                return true
            
            # -- Stream match! -- #
            
            if req.query.socket?
                # socket listener
                @sockets.addListener stream,req,res
                    
            else if req.query.off?
                # rewind to a starting offset
                new @Rewind.Listener stream, req, res, Number(req.query.off)
                    
            else if req.query.pump?
                # pump listener pushes from the buffer as fast as possible
                new @Outputs.pumper stream, req, res
                    
            else
                # normal live stream (with or without shoutcast)
                if req.headers['icy-metadata']
                    # -- shoutcast listener -- #
                    new @Outputs.shoutcast stream, req, res
                else
                    # -- straight mp3 listener -- #
                    new @Outputs.mp3 stream, req, res
                
        else
            @log.debug "Not Found", req:req
            next()
                            
    #----------
    
    class @Standalone extends Core
        constructor: (opts) ->
            @options = _u.defaults opts||{}, @DefaultOptions
            
            # -- Set up logging -- #
            
            @log = new Logger @options.log
            @log.debug("Instance initialized")
            
            # -- run Core's constructor -- #
            
            super()
            
            # -- set up our stream server -- #
            
            # init our server
            @server = express.createServer()
            @server.httpAllowHalfOpen = true
            @server.use (req,res,next) => @streamRouter(req,res,next)
            @server.listen @options.listen
                
            @log.debug "Standalone is listening on port #{@options.listen}"
        
            # start up the socket manager on the listener
            @sockets = new @Outputs.sockets server:@server, core:@
            
            # -- initialize streams -- #
            
            @configureStreams streams:@options.streams
    
    #----------
    
    # Master Server
    # 
    # Masters don't handle stream connections directly.  Instead they host 
    # configuration info and pass it on to slave servers.  They also consolidate 
    # slave logging data.
    
    class @Master extends Core
        constructor: (opts) ->
            @options = _u.defaults opts||{}, @DefaultOptions
            
            @slaves = []
            
            # -- set up logging -- #
            
            @log = new Logger @options.log
            @log.debug("Instance initialized")
            
            # -- allow Core's constructor to run -- #
            
            super()
            
            # -- load our streams configuration from redis -- #
            
            @redis = new @Redis @options.redis?
            @redis.on "config", (streams) =>
                # stash the configuration
                @options.streams = streams
                
                # and then pass it on to any connected slaves
                for sock in @slaves
                    sock.emit "config", streams:streams
            
            # -- set up the socket connection for slaves -- #
            
            if !@options.master?.port || !@options.master?.password
                @log.error("Invalid options for master server.  Must provide port and password.")
                return false                
                
            # fire up a socket listener on our slave port
            @io = require("socket.io").listen @options.master?.port
            
            # add our authentication
            @io.configure =>
                @io.set "authorization", (data,cb) =>
                    # look for password                    
                    if @options.master.password
                        # make sure we got the same password in the query
                        if @options.master.password == data.query?.password
                            cb null, true
                        else
                            cb "Invalid slave password.", false
                    else
                        cb null, true
            
            # look for slave connections    
            @io.on "connection", (sock) =>
                @log.debug "slave connection is #{sock.id}"
                
                if @options.streams
                    # emit our configuration
                    sock.emit "config", streams:@options.streams
                    
                @slaves.push sock
                
                # attach event handler for log reporting
                socklogger = @log.child slave:sock.handshake.address.address
                sock.on "log", (obj = {}) => 
                    socklogger[obj.level||debug].apply socklogger, [obj.msg||"",obj.meta||{}]
                
            # attach disconnect handler
            @io.on "disconnect", (sock) =>
                @log.debug "slave disconnect from #{sock.id}"
                @slaves = _u(@slaves).without sock


    #----------
    
    # Slave Server
    #
    # Slaves are born only knowing how to connect to their master. The master 
    # gives them stream configuration, which the slave then uses to connect 
    # and provide up streams to clients.  Logging data is always passed back 
    # to the master, but can optionally also be stored on the slave host.
    
    class @Slave extends Core
        constructor: (opts) ->
            @options = _u.defaults opts||{}, @DefaultOptions
            
            # -- Set up logging -- #
            
            @log = new Logger @options.log
            @log.debug("Instance initialized")
            
            # -- Make sure we have the proper slave config options -- #
            
            if !@options.slave?.master 
                @log.error "Invalid options for slave server. Must provide master."
                return false
                                
            # -- run Core's constructor -- #
            
            super()
            
            # -- set up our stream server -- #
            
            # init our server
            @server = express.createServer()
            @server.httpAllowHalfOpen = true
            @server.use (req,res,next) => @streamRouter(req,res,next)
            @server.listen @options.listen
                
            @log.debug "Slave is listening on port #{@options.listen}"
        
            # start up the socket manager on the listener
            @sockets = new @Outputs.sockets server:@server, core:@
                            
            # -- connect to the master server -- #
            
            @socket = require('socket.io-client').connect @options.slave.master
            
            @socket.on "connect", =>
                # connect up our logging proxy
                @log.proxyToMaster @socket
            
            @socket.on "config", (config) =>
                console.log "got config of ", config
                @configureStreams config
