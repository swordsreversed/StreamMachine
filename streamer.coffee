StreamMachine   = require "./src/streammachine"
nconf           = require "nconf"

# FIXME: Need to implement argv handling for version, help, etc

# -- do we have a config file to open? -- #

# get config from environment or command line
nconf.env().argv()

# add in config file
nconf.file( { file: nconf.get("config") || nconf.get("CONFIG") || "/etc/streammachine.conf" } )

# -- Defaults -- #

nconf.defaults StreamMachine.Defaults

if nconf.get("enable-webkit-devtools")
    console.log "ENABLING WEBKIT DEVTOOLS"
    agent = require("webkit-devtools-agent")
    agent.start()

# There are three potential modes of operation:
# 1) Standalone -- One server, handling boths streams and configuration
# 2) Master -- Central server in a master/slave setup. Does not handle any streams
#    directly, but hands out config info to slaves and gets back logging.
# 3) Slave -- Connects to a master server for stream information.  Passes back
#    logging data. Offers up stream connections to clients.

core = switch nconf.get("mode")
    when "master"
        new StreamMachine.MasterMode nconf.get()

    when "slave"
        new StreamMachine.SlaveMode nconf.get()

    else
        new StreamMachine.StandaloneMode nconf.get()