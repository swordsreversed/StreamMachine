BaseSource      = $src "sources/base"

fs = require "fs"

mp3 = $file "mp3/mp3-44100-64-s.mp3"

#----------

class TestSource extends BaseSource
    constructor: (@file,format) ->
        @opts = {}
        @opts.format = format
        @opts.chunkDuration = 0.5

        super

    start: ->
        @_file = fs.createReadStream @file
        @_file.pipe(@parser)

        @_file.on "end", => @emit "_read"

#----------

describe "Base Source", ->
    describe "Frame Chunker", ->
        describe "MP3 Processing", ->
            it "returns chunked data", (done) ->
                s = new TestSource mp3, "mp3"

                chunks = []
                s.on "_chunk", (chunk) ->
                    chunks.push chunk

                s.once "_read", ->
                    expect(chunks).to.have.length.above(1)
                    expect(chunks[0].duration).to.be.within(450,550)
                    done()

                s.start()