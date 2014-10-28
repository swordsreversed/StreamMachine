path    = require "path"
fs      = require "fs"
_       = require "underscore"


# RewindDumpRestore is in charge of making periodic backups of a RewindBuffer's
# data. This is important for helping a crashed process get back up to
# speed quickly. The `settings` should define the directory to write
# dump files into and the frequency in seconds with which dumps should
# occur.

module.exports = class RewindDumpRestore extends require('events').EventEmitter
    constructor: (@master,@settings) ->
        @_streams       = {}
        @_queue         = []
        @_working       = false
        @_shouldLoad    = false

        @log = @master.log.child(module:"rewind_dump_restore")

        # -- make sure directory is valid -- #

        @_path = fs.realpathSync( path.resolve( process.cwd(), @settings.dir ) )

        if (s = fs.statSync(@_path))?.isDirectory()
            # good
        else
            @log.error "RewindDumpRestore path (#{@_path}) is invalid."
            return false

        # -- create agents for each stream -- #

        for s,obj of @master.streams
            @_streams[ s ] = new Dumper obj, @_path

        # -- set our interval -- #

        if (@settings.frequency||-1) > 0
            @_int = setInterval =>
                @_triggerDumps()
            , @settings.frequency*1000


    #----------

    load: (cb) ->
        @_shouldLoad = true

        load_q = ( d for k,d of @_streams )

        results = success:0, errors:0

        _load = ->
            if d = load_q.shift()
                d._tryLoad (err,stats) =>
                    if err
                        @log.error "Load for #{ d.stream.key } errored: #{err}", stream:d.stream.key
                        results.errors += 1
                    else
                        results.success += 1

                    _load()
            else
                # done
                cb null, results

        _load()

    #----------

    _triggerDumps: ->
        @log.silly "Queuing Rewind dumps"
        @_queue.push ( d for k,d of @_streams )...

        @_dump() if !@_working

    #----------

    _dump: ->
        @_working = true

        if d = @_queue.shift()
            d._dump (err,file,timing) =>
                if err
                    @log.error "Dump for #{d.stream.key} errored: #{err}", stream:d.stream.key
                else
                    @log.silly "Dump for #{d.stream.key} succeeded in #{ timing }ms."

                # for tests...
                @emit "debug", "dump", d.stream.key, err, file:file, timing:timing

                @_dump()

        else
            @_working = false

    #----------

    class Dumper extends require('events').EventEmitter
        constructor: (@stream,@_path) ->
            @_i             = null
            @_active        = false
            @_loaded        = null
            @_tried_load    = false

            @_filepath = path.join(@_path,"#{@stream.key}.dump")

        #----------

        _tryLoad: (cb) ->
            # try loading our filepath. catch the error if it is not found
            rs = fs.createReadStream @_filepath

            rs.once "error", (err) =>
                @_setLoaded false
                cb err

            rs.once "open", =>
                @stream.rewind.loadBuffer rs, (err,stats) =>
                    @_setLoaded true
                    cb null, stats

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
                cb "RewindDumper failed: Already active for #{ @stream.key }"
                return false

            @_active = true
            start_ts = _.now()

            cb = _.once cb

            # -- open our output file -- #

            # To make sure we don't crash mid-write, we want to write to a temp file
            # and then get renamed to our actual filepath location.

            w = fs.createWriteStream "#{@_filepath}.new"

            w.once "open", =>
                @stream.rewind.dumpBuffer w, (err) =>
                    w.once "close", =>

                        if w.bytesWritten == 0
                            fs.unlink "#{@_filepath}.new", (err) =>
                                @_active = false
                                cb null, null

                        else
                            fs.rename "#{@_filepath}.new", @_filepath, (err) =>
                                if err
                                    cb err
                                    return false

                                end_ts = _.now()
                                @_active = false
                                cb null, @_filepath, end_ts - start_ts

            w.on "error", (err) =>
                cb err