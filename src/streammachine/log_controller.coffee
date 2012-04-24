_u = require "underscore"
winston = require "winston"

module.exports = class LogController
    DefaultOptions:
        foo: 'bar'
        
    CustomLevels:
        error:          50
        request:        40
        interaction:    30
        debug:          10
        
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
            # set up JSON logging via Bunyan
            transports.push new (winston.transports.File)
                level:      config.json?.level || "interaction"
                timestamp:  true
                filename:   config.json?.file
                json:       true
        
        # -- W3C -- #
        
        #if config.w3c?.file
            # set up W3C-format logging
            
        
        # -- Remote -- #
        
        # create a winston logger for this instance
        @logger = new (winston.Logger) transports:transports, levels:@CustomLevels, rewriters:[@RequestRewriter]
        @logger.extend(@)
        
    #----------
    
    # returns a logger that will automatically merge in the given data
    child: (opts={}) -> new LogController.Child(@,opts)
    
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
                        args.push @opts
                    
                    @parent[k].apply @, args