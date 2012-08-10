_u = require("underscore")
express = require "express"
path = require "path"

module.exports = class Router
    constructor: (opts) ->
        @core = opts?.core
        @server = express()
        @server.set "views", __dirname + "/views"
        @server.set "view engine", "hamlc"
        @server.engine '.hamlc', require('haml-coffee').__express
        
        # -- Routing -- #
        
        @server.get "/", (req,res) =>
            console.log "sockets is ", @core.sockets.io
            res.render "layout", core:@core