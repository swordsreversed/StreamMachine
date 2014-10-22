path    = require "path"
fs      = require "fs"
_       = require "underscore"


# RewindDumper is in charge of making periodic backups of a RewindBuffer's
# data. This is important for helping a crashed process get back up to
# speed quickly. The `settings` should define the directory to write
# dump files into and the frequency in seconds with which dumps should
# occur.

module.exports = class RewindDumper extends require('events').EventEmitter
    constructor: (@rewind,@settings) ->
        @_i             = null
        @_active        = false
        @_loaded        = null
        @_tried_load    = false

        # -- make sure directory is valid -- #

        @_path = fs.realpathSync( path.resolve( process.cwd(), @settings.dir ) )

        if (s = fs.statSync(@_path))?.isDirectory()
            # good
        else
            console.error "RewindDumper path is invalid."
            throw "Invalid RewindDumper path: #{ @_path }"

        @_filepath = path.join(@_path,"#{@rewind._rkey}.dump")

        # -- is there a file to load? -- #

        @_tryLoad()

        # -- set a timer to do the save -- #

        if @settings.frequency > 0
            @once "loaded", =>
                console.log "RewindDumper setting interval of #{ @settings.frequency }"
                @_i = setInterval =>
                    @_dump (err,fp) =>
                        # do nothing
                , @settings.frequency*1000

    #----------

    _tryLoad: (cb) ->
        # try loading our filepath. catch the error if it is not found
        rs = fs.createReadStream @_filepath

        rs.once "error", (err) =>
            console.error "RewindDumper tryLoad read error: #{err}", err
            @_setLoaded false

        rs.once "open", =>
            console.log "tryLoad read open"
            @rewind.loadBuffer rs, (err,stats) =>
                console.log "RewindDumper tryLoad success", stats
                @_setLoaded true

    #----------

    _setLoaded: (status) ->
        @_loaded        = status
        @_tried_load    = true
        @emit "loaded", status

    #----------

    once_loaded: (cb) ->
        if @_tried_load
            cb?()
        else
            @once "loaded", cb

    #----------

    _dump: (cb) ->
        if @_active
            console.error "RewindDumper failed: Already active for #{ @rewind._rkey }"
            return false

        @_active = true
        start_ts = _.now()

        cb = _.once cb

        # -- open our output file -- #

        # To make sure we don't crash mid-write, we want to write to a temp file
        # and then get renamed to our actual filepath location.

        console.log "opening dumper out at #{@_filepath}.new"

        w = fs.createWriteStream "#{@_filepath}.new"

        w.once "open", =>
            @rewind.dumpBuffer w, (err) =>
                w.once "close", =>

                    if w.bytesWritten == 0
                        fs.unlink "#{@_filepath}.new", (err) =>
                            @_active = false
                            cb null, null

                    else
                        console.log "RewindDumper doing rename: #{@_filepath}.new -> #{ @_filepath }"
                        fs.rename "#{@_filepath}.new", @_filepath, (err) =>
                            if err
                                console.error "RewindDumper rename failed: #{err}"
                                cb err
                                return false

                            end_ts = _.now()
                            console.log "RewindDumper dump finished. Took #{ end_ts - start_ts }ms."
                            @_active = false
                            cb null, @_filepath

        w.on "error", (err) =>
            console.error "RewindDumper error: ", err
            cb err