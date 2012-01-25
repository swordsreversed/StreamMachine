lame = require("lame")
fs = require('fs')

mp3 = fs.createReadStream("/Users/eric/Downloads/20120121_offramp.mp3")

parser = lame.createParser()

parser.on "header", (data,header) ->
    console.log "header: ", data

parser.on "frame", (data) ->
    console.log "frame: ", data

mp3.on "data", (chunk) -> parser.write(chunk)

