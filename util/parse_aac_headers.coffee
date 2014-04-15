AAC = require "../src/streammachine/parsers/aac"
_ = require "underscore"

aac = new AAC

firstHeader = null
headerCount = 0

aac.on "header", (obj) =>
    headerCount += 1

    if firstHeader
        if _.isEqual(firstHeader,obj)
            # do nothing
        else
            console.log "Header #{headerCount}: ", obj

    else
        firstHeader = obj
        console.log "First header: ", obj

process.stdin.pipe aac