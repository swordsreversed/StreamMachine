RewindBuffer    = require "../src/streammachine/rewind_buffer"
Logger          = require "../src/streammachine/logger"

path = require "path"
fs = require "fs"

filepath = process.argv[2]

if !filepath
    console.error "A file path is required."
    process.exit(1)

filepath = path.resolve(filepath)

if !fs.existsSync(filepath)
    console.error "File not found."
    process.exit(1)

log     = new Logger stdout:true
rewind  = new RewindBuffer seconds:999999, burst:30, key:"inspector", log:log

file = fs.createReadStream filepath

rewind.loadBuffer file, (err,stats) =>
    console.log "loadBuffer complete: ", stats

    rewind._rbuffer.clone (err,clone) =>
        # -- look for discontinuities -- #

        next_ts = null
        for b,i in clone
            if next_ts
                # is next_ts ~= b.ts?
                if (next_ts - 50 > Number(b.ts)) || (Number(b.ts) > next_ts + 50)
                    console.log "Gap? #{i}\n  Got: #{b.ts}\n  Expected: #{ new Date(next_ts) }\n  Offset: #{ Number(b.ts - next_ts) }"

            next_ts = Number(b.ts) + b.duration
