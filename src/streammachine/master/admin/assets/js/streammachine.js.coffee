###
StreamMachine
###

window.streammachine ?= {}

# stub console.log() for IE
if !window.console
    class window.console
        @log: ->


