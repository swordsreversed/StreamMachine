require("coffee-script/register")

cluster         = require("cluster")
nconf           = require("nconf")
StreamMachine   = require("../")

nconf.env().argv()

// add in config file
nconf.file( { file: nconf.get("config") || nconf.get("CONFIG") || "/etc/streammachine.conf" } )

// -- Defaults -- #

nconf.defaults(StreamMachine.Defaults)

process.title = "StreamM:slaveWorker"
worker = new StreamMachine.SlaveMode.SlaveWorker()