_u = require "underscore"
nconf = require "nconf"

Logger  = require "../logger"
Slave   = require "../slave"

# Slave Server
#
# Slaves are born only knowing how to connect to their master. The master 
# gives them stream configuration, which the slave then uses to connect 
# and provide up streams to clients.  Logging data is always passed back 
# to the master, but can optionally also be stored on the slave host.

module.exports = class SlaveMode extends require("./base")
    
    MODE: "Slave"
    constructor: (@opts) ->
        @log = new Logger opts.log
        @log.debug("Slave Instance initialized")
        
        process.title = "StreamM:slave"
        
        super
        
        # create a slave
        @slave = new Slave _u.extend @opts, logger:@log
        
        if nconf.get("handoff")
            @_acceptHandoff()
            
        else
            @log.info "Slave listening."
            @slave.server.listen @opts.port
    
    #----------
    
    _sendHandoff: (translator) ->
        @log.info "Starting slave handoff."
        
        # Send our public handle
        translator.send "server_socket", {}, @slave.server.hserver
        
        translator.once "server_socket_up", =>
            @log.info "Server socket transferred. Sending listener connections."
        
            # Send slave data
            @slave.sendHandoffData translator, (err) =>
                @log.event "Sent slave data to new process. Exiting."

                # Exit
                process.exit()
            
    _acceptHandoff: ->
        @log.info "Initializing handoff receptor."
        
        if !process.send?
            @log.error "Handoff called, but process has no send function. Aborting."
            return false
            
        console.log "Sending GO"
        process.send "HANDOFF_GO"
        
        # set up our translator
        translator = new SlaveMode.HandoffTranslator process
        
        @slave.once "streams", =>
            # signal that we are configured
            translator.send "streams"
            
            translator.once "server_socket", (msg,handle) =>
                @log.info "Got server socket."
                @slave.server.listen handle
                @log.info "Accepting new connections."
                translator.send "server_socket_up"
                
            # Watch for any transferred listeners
            @slave.loadHandoffData translator
        