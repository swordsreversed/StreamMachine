Preroller   = $src "slave/preroller"
SlaveStream = $src "slave/stream"
Logger      = $src "logger"

fs = require "fs"
debug = require("debug")("sm:tests:preroller")

mp3 = $file "mp3/tone250Hz-44100-128-m.mp3"

STREAM1 =
    key:                "test1"
    source_password:    "abc123"
    root_route:         true
    seconds:            60*60*4
    format:             "mp3"
    log_minutes:        false
    max_buffer:         2*1024*1024

http = require "http"

describe "Preroller", ->
    logger = new Logger {}

    describe "XML Ad Formats", ->
        doc = ""
        
        before (done) ->
            debug "Loading VAST doc"
            s = fs.createReadStream $file "ads/vast.xml"
            s.on "readable", ->
                doc += r while r = s.read()
            
            s.once "end", ->
                debug "VAST XML loaded. Length is #{doc.length}."
                done()
        
        it "Parses VAST ad", (done) ->
            new Preroller.AdObject doc, (err,obj) ->
                throw err if err
                
                expect(obj.creativeURL).to.eql "AUDIO"
                expect(obj.impressionURL).to.eql "IMPRESSION"
                done()
            

