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
        
        # attach our assets
        asset_path = path.join(__dirname,"..","..","..","assets")
            
        @server.use require('express-partials')()
        @server.use require('less-middleware') src:asset_path
        @server.use(express.static(asset_path))

        # -- Routing -- #
        
        @server.get "/", (req,res) =>
            res.render "index", core:@core