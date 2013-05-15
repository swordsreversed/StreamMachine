_u      = require "underscore"
url     = require 'url'
http    = require "http"
nconf   = require "nconf"



module.exports = class StreamMachine
    @StandaloneMode: require "./modes/standalone"
    @MasterMode:     require "./modes/master"
    @SlaveMode:      require "./modes/slave"
                                        
    #----------
    
    class @HandoffTranslator extends require("events").EventEmitter
        constructor: (@p) ->
            @p.on "message", (msg,handle) =>
                console.log "TRANSLATE GOT #{msg.key}", msg, handle?
                if msg?.key
                    msg.data = {} if !msg.data
                    @emit msg.key, msg.data, handle
            
        send: (key,data,handle=null) ->
            console.log "TRANSLATE #{key}", data, handle?
            @p.send { key:key, data:data }, handle
        
