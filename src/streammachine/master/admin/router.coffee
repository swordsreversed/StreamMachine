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
            
        @app.post "/api/streams", (req,res) =>
            # add a new stream
            
            # TODO... this needs to trigger an update that writes into Redis
            
        @app.get "/api/streams/:stream", (req,res) =>
            # get detailed stream information
            res.status(200).end JSON.stringify req.stream.status(true)
            
        @app.post "/api/streams/:stream/promote", (req,res) =>
            # promote a stream source to active
            # We'll just pass on the UUID and leave any logic to the stream
            req.stream.promoteSource req.query.uuid, (err,msg) =>
                if err
                    res.status(200).end JSON.stringify error:err
                else
                    res.status(200).end JSON.stringify msg
            
        @app.post "/api/streams/:stream/drop", (req,res) =>
            # drop a stream source
            
        @app.delete "/api/streams/:stream", (req,res) =>
            # delete a stream
            
        @server = @app.listen @port
###
API:

/streams
-- Get stream information (is source connected, etc)

/streams/(stream)
-- Get detailed information on one stream

/streams/(stream)/promote
###                
        