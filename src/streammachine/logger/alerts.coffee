winston = require "winston"

module.exports = class Alerts extends winston.Transport
    name: "alerts"
    
    constructor: (@options) ->
        super level:@options.level
                    
        # what alert systems are we opening?
        
    log: (level,msg,meta,cb) ->
        console.log "Alerts got ", level, msg
        
        cb? null, true
    