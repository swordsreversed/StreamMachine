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

        # -- make sure directory is valid -- #

        @_path = fs.realpathSync( path.resolve( process.cwd(), @settings.dir ) )

        if (s = fs.statSync(@_path))?.isDirectory()
            # good
        else
            console.error "RewindDumper path is invalid."
            throw "Invalid RewindDumper path: #{ @_path }"

        @_filepath = path.join(@_path,"#{@rewind._rkey}.dump")

        # -- set a timer to do the save -- #

        console.log "RewindDumper setting interval of #{ @settings.frequency }"
        @_i = setInterval =>
            @_dump()
        , @settings.frequency*1000

    #----------

    _dump: (cb) ->
        if @_active
            console.error "RewindDumper failed: Already active for #{ @rewind._rkey }"
            return false

        @_active = true
        start_ts = _.now()

        cb = _.once cb

        # -- open our output file -- #

        console.log "opening dumper out at #{@_filepath}"

        w = fs.createWriteStream @_filepath

        w.once "open", =>
            @rewind.dumpBuffer w, (err) =>
                w.once "close", =>
                    end_ts = _.now()
                    console.log "RewindDumper dump finished. Took #{ end_ts - start_ts }ms."
                    @_active = false
                    cb null, @_filepath

        w.on "error", (err) =>
            console.error "RewindDumper error: ", err
            cb err