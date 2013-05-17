_u = require "underscore"
express = require "express"
nconf = require "nconf"

Logger  = require "../logger"
Master  = require "../master"

# Master Server
# 
# Masters don't take client connections directly. They take incoming 
# source streams and proxy them to the slaves, providing an admin 
# interface and a point to consolidate logs and listener counts.

module.exports = class MasterMode extends require("./base")
    
    MODE: "Master"
    constructor: (opts) ->
        @log = new Logger opts.log
        @log.debug("Master Instance initialized")
        
        # create a master
        @master = new Master _u.extend {}, opts, logger:@log
        
        # Set up a server for our admin
        @server = express()
        @server.use "/s", @master.transport.app
        @server.use @master.admin.app
        
        if nconf.get("handoff")
            @_acceptHandoff()
            
        else
            @log.info "Listening."
            @handle = @server.listen opts.master.port
            @master.listenForSlaves(@handle)
            @master.sourcein.listen()

    #----------
    
    _sendHandoff: ->
    
    _acceptHandoff: ->