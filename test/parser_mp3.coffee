MP3 = $src "parsers/mp3"
fs  = require "fs"

describe "MP3 Parser", ->
    describe "Stream Key Generation", ->
        testKey = (fmt,cb) ->
            mp3 = new MP3
            f = fs.createReadStream($file "mp3/#{fmt}.mp3")
                        
            mp3.once "header", (raw,parsed) ->
                expect(fmt).to.equal parsed.stream_key
                cb()
            
            f.pipe(mp3)
                            
        for k in ["mp3-44100-128-s","mp3-44100-64-s","mp3-22050-128-s","mp3-22050-64-s","mp3-22050-64-s"]
            it "correctly identifies format information (#{k})", (done) ->
                testKey k, done
