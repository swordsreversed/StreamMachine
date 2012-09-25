_u = require("underscore")
express = require "express"
path = require "path"

module.exports = class Router
    constructor: (opts) ->
        @core = opts?.core
        @port = opts?.port
        
        @app = express()
        @app.set "views", __dirname + "/views"
        @app.set "view engine", "hamlc"
        @app.engine '.hamlc', require('haml-coffee').__express
        
        # -- Routing -- #
        
        @app.get "/", (req,res) =>
            res.render "layout", core:@core
            
        # -- Socket Requests -- #
        
        

        @server.once "io_connected", (@io) =>
            @io.of("/ADMIN").on "connection", (sock) =>
                sock.emit "welcome", @core.stream_info()
        
                
###
API:

/streams
-- Get stream information (is source connected, etc)

/streams/(stream)
-- Get detailed information on one stream

/streams/(stream)/promote
###                
        