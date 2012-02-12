StreamMachine = require("./src/streammachine/core")

core = new StreamMachine
    listen:     8000
    streams:
        kpcclive:
            source: type:"proxy", url:"http://206.221.211.12:80/"
            rewind: seconds:(60*60*4)   # 4 hour buffer
        thecurrent:
            source: type:"proxy", url:"http://currentstream1.publicradio.org:80/"
            rewind: seconds:(60*30)     # 30 minute buffer
    
console.log "Core is ", core

#ProxyRoom = require "./src/proxy_room"
#Caster = require "./src/caster"

# connect our proxy to the SCPR stream
#(proxy = new ProxyRoom url:"http://206.221.211.12:80/").connect()

#cast = new Caster 
#    source:     proxy
#    port:       8080