_u              = require("underscore")
express         = require "express"
api             = require "express-api-helper"
path            = require "path"
passport        = require "passport"
BasicStrategy   = (require "passport-http").BasicStrategy
Throttle        = require "throttle"

Users = require "./users"

module.exports = class API
    constructor: (@master,require_auth=false) ->
        @log = @master.log.child component:"admin"

        @app = express()

        # -- set up authentication -- #

        @users = new Users.Local @

        if require_auth
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
            else if key? && sg = @master.stream_groups[ key ]
                req.stream = sg._stream
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

        @app.get "/listeners", (req,res) =>
            if @master.analytics
                @master.analytics.countListeners (err,listeners) =>
                    if err
                        api.invalid req, res, err
                    else
                        api.ok req, res, listeners
            else
                api.invalid req, res, "Analytics function is required by listeners endpoint."

        # list streams
        @app.get "/streams", (req,res) =>
            # return JSON version of the status for all streams
            api.ok req, res, @master.streamsInfo()

        # list stream groups
        @app.get "/stream_groups", (req,res) =>
            # return JSON version of the status for all streams
            api.ok req, res, @master.groupsInfo()

        # list source mounts
        @app.get "/sources", (req,res) =>
            api.ok req, res, @master.sourcesInfo()

        # list streams
        @app.get "/config", (req,res) =>
            # return JSON version of the status for all streams
            api.ok req, res, @master.config()

        # list slaves
        @app.get "/slaves", (req,res) =>
            api.ok req, res, @master.slavesInfo()

        # create a stream
        @app.post "/streams", express.bodyParser(), (req,res) =>
            # add a new stream
            @master.createStream req.body, (err,stream) =>
                if err
                    api.invalid req, res, err
                else
                    api.ok req, res, stream

        # get stream details
        @app.get "/streams/:stream", (req,res) =>
            # get detailed stream information
            api.ok req, res, req.stream.status()

        # get stream configuration
        @app.get "/streams/:stream/config", (req,res) =>
            api.ok req, res, req.stream.config()

        # update stream metadata
        @app.post "/streams/:stream/metadata", express.bodyParser(), (req,res) =>
            req.stream.setMetadata req.body||req.query, (err,meta) =>
                if err
                    api.invalid req, res, err
                else
                    api.ok req, res, meta

        # Promote a source to live
        @app.post "/streams/:stream/promote", (req,res) =>
            # promote a stream source to active
            # We'll just pass on the UUID and leave any logic to the stream
            req.stream.promoteSource req.query.uuid, (err,msg) =>
                if err
                    api.invalid req, res, err
                else
                    api.ok req, res, msg

        # Drop a source
        @app.post "/streams/:stream/drop", (req,res) =>
            source = _u(req.stream.sources).find((s) -> s.uuid == req.query.uuid)
            if source then source.disconnect()
            api.ok req, res


        # Update a stream's configuration
        @app.put "/streams/:stream/config", express.bodyParser(), (req,res) =>
            @master.updateStream req.stream, req.body, (err,obj) =>
                if err
                    api.invalid req, res, err
                else
                    api.ok req, res, obj

        # Delete a stream
        @app.delete "/streams/:stream", (req,res) =>
            @master.removeStream req.stream, (err,obj) =>
                if err
                    api.invalid req, res, err
                else
                    api.ok req, res, obj

        # Dump a RewindBuffer
        @app.get "/streams/:stream/rewind", (req,res) =>
            res.status(200).write ''
            req.stream.getRewind (err,io) =>
                # long story... may be related to https://github.com/joyent/node/issues/6065
                # in any case, piping to /dev/null went too fast and crashed the server.
                # Throttling fixes it
                io.pipe( new Throttle 100*1024*1024 ).pipe(res)

        # Clear a Rewind Buffer
        @app.delete "/streams/:stream/rewind", (req,res) =>
            req.stream.rewind.resetRewind (err) =>
                if err
                    api.invalid req, res, err
                else
                    api.ok req, res, req.stream.status()

        # -- User Management -- #

        # get a list of users
        @app.get "/users", (req,res) =>
            @users.list (err,users) =>
                if err
                    api.serverError req, res, err
                else
                    obj = []

                    obj.push { user:u, id:u } for u in users

                    api.ok req, res, obj

        # create / update a user
        @app.post "/users", express.bodyParser(), (req,res) =>
            @users.store req.body.user, req.body.password, (err,status) =>
                if err
                    api.invalid req, res, err
                else
                    api.ok req, res, ok:true

        # delete a user
        @app.delete "/users/:user", (req,res) =>
            @users.store req.params.user, null, (err,status) =>
                if err
                    api.invalid req, res, err
                else
                    api.ok req, res, ok:true
