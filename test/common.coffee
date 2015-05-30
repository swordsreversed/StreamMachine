StreamMachine   = require "../src/streammachine"
nconf           = require "nconf"

chai            = require "chai"
global.expect   = chai.expect

nconf.env().argv()
nconf.file( { file: nconf.get("config") || nconf.get("CONFIG") || "config/test.json" } )

nconf.defaults StreamMachine.Defaults

path = require "path"
global.$src     = (module) -> require path.resolve(__dirname,"..","src","streammachine",module)
global.$file    = (file) -> path.resolve(__dirname,"files",file)
