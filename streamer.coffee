StreamMachine = require("./src/streammachine/core")
nconf = require("nconf")

# -- do we have a config file to open? -- #

# get config from environment or command line
nconf.env().argv()

# add in config file
nconf.file( { file: nconf.get("config") || nconf.get("CONFIG") || "/etc/streammachine.conf" } )

#console.log "config file master is #{nconf.get("master")}"

#exit()

if nconf.get("master")
    # we're a slave server, connecting to a master
    # need to make sure we also have a setting for master:password
    core = new StreamMachine.Slave nconf.get("master")
    
    console.log "Core is connected as a slave."
else
    core = new StreamMachine
        listen:     nconf.get("port")
        log:        nconf.get("log")
        slaves:     nconf.get("slaves")    
    .configure
        streams:    nconf.get("streams")
    
    console.log "Core is connected as a master."