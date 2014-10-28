_u              = require("underscore")
express         = require "express"
api             = require "express-api-helper"
path            = require "path"
hamlc           = require "haml-coffee"
Mincer          = require "mincer"
passport        = require "passport"
BasicStrategy   = (require "passport-http").BasicStrategy
Throttle        = require "throttle"

Users = require "./users"

module.exports = class Router
    constructor: (@master) ->
        @log = @master.log.child component:"admin"

        @app = express()
        @app.set "views",       __dirname + "/views"
        @app.set "view engine", "hamlc"
        @app.engine '.hamlc',   hamlc.__express

        mincer = new Mincer.Environment()
        mincer.appendPath __dirname + "/assets/js"
        mincer.appendPath __dirname + "/assets/css"

        @app.use('/assets', Mincer.createServer(mincer))

        # -- set up authentication -- #

        @users = new Users.Local @

        passport.use new BasicStrategy (user,passwd,done) =>
            @users.validate user, passwd, done

        @app.use passport.initialize()

        @app.use passport.authenticate('basic', { session: false })

        # -- Param Handlers -- #

        @app.param "stream", (req,res,next,key) =>
            # make sure it's a valid stream key
            if key? && s = @master.streams[ key ]
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

        @app.get "/api/listeners", (req,res) =>
            if @master.analytics
                @master.analytics.countListeners (err,listeners) =>
                    if err
                        api.invalid req, res, err
                    else
                        api.ok req, res, listeners

        # list streams
        @app.get "/api/streams", (req,res) =>
            # return JSON version of the status for all streams
            api.ok req, res, @master.streamsInfo()

        # list stream groups
        @app.get "/api/stream_groups", (req,res) =>
            # return JSON version of the status for all streams
            api.ok req, res, @master.groupsInfo()

        # list streams
        @app.get "/api/config", (req,res) =>
            # return JSON version of the status for all streams
            api.ok req, res, @master.config()

        # list slaves
        @app.get "/api/slaves", (req,res) =>
            api.ok req, res, @master.slavesInfo()

        # create a stream
        @app.post "/api/streams", express.bodyParser(), (req,res) =>
            # add a new stream
            @master.createStream req.body, (err,stream) =>
                if err
                    api.invalid req, res, err
                else
                    api.ok req, res, stream

        # get stream details
        @app.get "/api/streams/:stream", (req,res) =>
            # get detailed stream information
            api.ok req, res, req.stream.status()

        # update stream metadata
        @app.post "/api/streams/:stream/metadata", express.bodyParser(), (req,res) =>
            req.stream.setMetadata req.body||req.query, (err,meta) =>
                if err
                    api.invalid req, res, err
                else
                    api.ok req, res, meta

        # Promote a source to live
        @app.post "/api/streams/:stream/promote", (req,res) =>
            # promote a stream source to active
            # We'll just pass on the UUID and leave any logic to the stream
            req.stream.promoteSource req.query.uuid, (err,msg) =>
                if err
                    api.invalid req, res, err
                else
                    api.ok req, res, msg

        # Drop a source
        @app.post "/api/streams/:stream/drop", (req,res) =>
            source = _u(req.stream.sources).find((s) -> s.uuid == req.query.uuid)
            if source then source.disconnect()
            api.ok req, res


        # Update a stream's configuration
        @app.put "/api/streams/:stream", express.bodyParser(), (req,res) =>
            @master.updateStream req.stream, req.body, (err,obj) =>
                if err
                    api.invalid req, res, err
                else
                    api.ok req, res, obj

        # Delete a stream
        @app.delete "/api/streams/:stream", (req,res) =>
            @master.removeStream req.stream, (err,obj) =>
                if err
                    api.invalid req, res, err
                else
                    api.ok req, res, obj

        # Dump a RewindBuffer
        @app.get "/api/streams/:stream/rewind", (req,res) =>
            res.status(200).write ''
            req.stream.getRewind (err,io) =>
                # long story... may be related to https://github.com/joyent/node/issues/6065
                # in any case, piping to /dev/null went too fast and crashed the server.
                # Throttling fixes it
                io.pipe( new Throttle 100*1024*1024 ).pipe(res)

        # Clear a Rewind Buffer
        @app.delete "/api/streams/:stream/rewind", (req,res) =>
            req.stream.rewind.resetRewind (err) =>
                if err
                    api.invalid req, res, err
                else
                    api.ok req, res, req.stream.status()

        # -- User Management -- #

        # get a list of users
        @app.get "/api/users", (req,res) =>
            @users.list (err,users) =>
                if err
                    api.serverError req, res, err
                else
                    obj = []

                    obj.push { user:u, id:u } for u in users

                    api.ok req, res, obj

        # create / update a user
        @app.post "/api/users", express.bodyParser(), (req,res) =>
            @users.store req.body.user, req.body.password, (err,status) =>
                if err
                    api.invalid req, res, err
                else
                    api.ok req, res, ok:true

        # delete a user
        @app.delete "/api/users/:user", (req,res) =>
            @users.store req.params.user, null, (err,status) =>
                if err
                    api.invalid req, res, err
                else
                    api.ok req, res, ok:true

        # -- Serve the UI -- #

        # Get the web UI
        @app.get /.*/, (req,res) =>
            path = if @app.path() == "/" then "" else @app.path()
            res.render "layout",
                core:       @master
                server:     "http://#{req.headers.host}#{path}/api"
                streams:    JSON.stringify(@master.streamsInfo())
                path:       path
