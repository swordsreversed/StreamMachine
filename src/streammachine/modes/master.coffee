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
        @master = new Master _u.extend opts, logger:@log
        
        # Listen on the master port
        @server = @master.admin.listen opts.master.port
        
        # Also attach sockets for slaves
        @master.listenForSlaves(@server)