_u = require "underscore"
winston = require "winston"
fs = require "fs"
path = require "path"
strftime = require("prettydate").strftime

module.exports = class LogController
    CustomLevels:
        error:          80
        alert:          75
        event:          70
        info:           60
        request:        40
        interaction:    30
        minute:         30
        debug:          10
        silly:          5
        
    constructor: (config) ->
                            
        transports = []
        
        # -- stdout -- #
        
        if config.stdout
            console.log "adding Console transport"
            transports.push new (winston.transports.Console)
                level:      config.stdout?.level        || "debug"
                colorize:   config.stdout?.colorize     || false
                timestamp:  config.stdout?.timestamp    || false
        
        # -- JSON -- #
        
        if config.json?.file
            console.log "Setting up JSON logger with ", config.json
            # set up JSON logging via Bunyan
            transports.push new (winston.transports.File)
                level:      config.json.level || "interaction"
                timestamp:  true
                filename:   config.json.file
                json:       true
                options:
                    flags: 'a'
                    highWaterMark: 24
        
        # -- W3C -- #
        
        if config.w3c?.file
            # set up W3C-format logging
            transports.push new LogController.W3CLogger
                level:      config.w3c.level || "request"
                filename:   config.w3c.file
                
        # -- Cube -- #
        
        if config.cube?.server
            # set up cube logging
            transports.push new LogController.CubeLogger
                server:     config.cube.server
                event:      config.cube.event
                level:      "minute"
                
        # -- Campfire -- #
        
        if config.campfire?
            # set up logging to a Campfire room
            transports.push new LogController.CampfireLogger config.campfire
        
        # -- Remote -- #
        
        # create a winston logger for this instance
        @logger = new (winston.Logger) transports:transports, levels:@CustomLevels, rewriters:[@RequestRewriter]
        @logger.extend(@)
        
    #----------
    
    # returns a logger that will automatically merge in the given data
    child: (opts={}) -> new LogController.Child(@,opts)
    
    #----------
    
    # connect to our events and proxy interaction and request events through 
    # to a master server over WebSockets
    proxyToMaster: (sock) ->
        @logger.remove(@logger.transports['socket']) if @logger.transports['socket']
        @logger.add (new LogController.SocketLogger sock, level:"interaction"), {}, true if sock
    
    #----------
    
    RequestRewriter: (level,msg,meta) ->
        if meta?.req
            req = meta.req
            
            meta.req = 
                method:         req.method
                url:            req.url
                headers:        req.headers
                remoteAddress:  req.connection.remoteAddress
                remotePort:     req.connection.remotePort
                        
        meta

    #----------
    
    class @Child
        constructor: (@parent,@opts) ->
            _u(['log', 'profile', 'startTimer'].concat(Object.keys(@parent.logger.levels))).each (k) =>
                @[k] = (args...) => 
                    if _u.isObject(args[args.length-1])
                        args[args.length-1] = _u.extend {}, args[args.length-1], @opts
                    else
                        args.push _u.clone(@opts)
                    
                    @parent[k].apply @, args
                    
            @child = (opts={}) -> new LogController.Child(@parent,_u.extend({},@opts,opts))
                    
    #----------
    
    class @W3CLogger extends winston.Transport
        name: "w3c"
        
        constructor: (options) ->
            super(options)
            
            @options = options
            
            @_opening   = false
            @_file      = null
            @_queue = []
            
            process.addListener "SIGHUP", =>
                # re-open our log file
                console.log "w3c reloading log file"
                @close => @open()
                
        #----------
        
        log: (level,msg,meta,cb) ->
            # unlike a normal logging endpoint, we only care about our request entries
            if level == @options.level                        
                # for a valid w3c log, level should == "request", meta.
                logline = "#{meta.ip} #{strftime(new Date(meta.time),"%F %T")} #{meta.path} 200 #{escape(meta.ua)} #{meta.bytes} #{meta.seconds}"
            
                @_queue.push logline
                @_runQueue()
        
        #----------
        
        _runQueue:  ->
            if @_file
                # we're open, so do a write...
                if @_queue.length > 0
                    line = @_queue.shift()
                    @_file.write line+"\n", "utf8", =>
                        @_runQueue if @_queue.length > 0
                
            else
                @open (err) => @_runQueue()
        
        #----------
        
        open: (cb) ->
            if @_opening
                console.log "W3C already opening... wait."
                # we're already trying to open.  return an error so we queue the message
                return false
                
            console.log "W3C opening log file."
            
            # note that we're opening, and also set a timeout to make sure 
            # we don't get stuck
            @_opening = setTimeout =>
                console.log "Failed to open w3c log within one second."
                @_opening = false
                @open(cb)
            , 1000
            
            # is this a new file or one that we're just re-opening?
            initFile = true
            if fs.existsSync(@options.filename)
                # file exists...  see if there's anything in it
                stats = fs.statSync(@options.filename)
                
                if stats.size > 0
                    # existing file...  don't write headers, just open so we can 
                    # start appending
                    initFile = false
            
            @_file = fs.createWriteStream @options.filename, flags:(if initFile then "w" else "r+")
            
            @_file.once "open", (err) =>
                console.log "w3c log open with ", err
                
                _clear = =>
                    console.log "w3c open complete"
                    clearTimeout @_opening if @_opening
                    @_opening = null
                    cb?()
                
                if initFile
                    # write our initial w3c lines before we return
                    @_file.write "#Software: StreamMachine\n#Version: 0.2.9\n#Fields: c-ip date time cs-uri-stem c-status cs(User-Agent) sc-bytes x-duration\n", "utf8", =>
                        _clear()
                    
                else
                    _clear()
                            
        #----------
            
        close: (cb) ->
            @_file?.end null, null, =>
              console.log "W3C log file closed."
            @_file = null
            
        #----------
        
        flush: ->
            @_runQueue()
            
    #----------
    
    class @CampfireLogger extends winston.Transport
        name: "campfire"
        
        constructor: (@opts) ->
            super @opts
        
            # -- build our connection -- #
        
            Campfire = (require "campfire").Campfire
  
            @_room  = false
            @_queue = []

            @campfire = new Campfire 
                account:  @opts.account
                token:    @opts.token
                ssl:      true

            @campfire.join @opts.room, (err,room) =>
                if err
                    console.error "Cannot connect to Campfire for logging: #{err}"
                    return false
                    
                @_room = room
                
                for msg in @_queue
                    @_room.speak msg, (err) =>
                        # ok

                @_queue = []
                    
        log: (level,msg,meta,cb) ->
            if @_room
                @_room.speak msg, (err) =>
                    # ok
            else
                @_queue.push msg
            
            cb?()
    
    #----------
    
    class @SocketLogger extends winston.Transport
        name: "socket"
        
        constructor: (@sock,opts) ->
            super(opts)
            
        log: (level,msg,meta,cb) ->
            @sock.emit "log", level:level, msg:msg, meta:meta
            cb?()
            
    #----------
            
    class @CubeLogger extends winston.Transport
        name: "cube"
        
        constructor: (opts) ->
            super(opts)
            @options = opts
            
            @socket = null
            @openSocket()
            
        #----------
        
        log: (level,msg,meta,cb) ->
            if level == @options.level
                @socket.send type:@options.event, time:meta.time, data:meta if @socket
            
        #----------
            
        openSocket: ->
            @socket = new require("cube").emitter(@options.server)            