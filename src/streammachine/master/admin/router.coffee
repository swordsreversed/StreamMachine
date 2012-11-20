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
        
        # -- Param Handlers -- #
        
        @app.param "stream", (req,res,next,key) =>
            # make sure it's a valid stream key
            if key? && s = @core.streams[ key ]
                req.stream = s
                next()
            else
                res.status(404).end "Invalid stream.\n"
                
        # -- options support for CORS -- #
        
        corsFunc = (req,res,next) =>
          res.header('Access-Control-Allow-Origin', '*');
          res.header('Access-Control-Allow-Credentials', true); 
          res.header('Access-Control-Allow-Methods', 'POST, GET, PUT, DELETE, OPTIONS');
          res.header('Access-Control-Allow-Headers', 'Content-Type'); 
          next()
        
        @app.use corsFunc
      
        @app.options "*", (req,res) =>
            res.status(200).end ""
            
        # -- Routing -- #
                
        @app.get "/", (req,res) =>
            res.render "layout", core:@core
            
        @app.get "/api/streams", (req,res) =>
            # return JSON version of the status for all streams
            res.status(200).end JSON.stringify @core.streamsInfo()
            
        @app.get "/api/streams/:stream", (req,res) =>
            
        @server = @app.listen @port
###
API:

/streams
-- Get stream information (is source connected, etc)

/streams/(stream)
-- Get detailed information on one stream

/streams/(stream)/promote
###                
        