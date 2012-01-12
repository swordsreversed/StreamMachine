ProxyRoom = require "./src/proxy_room"
Caster = require "./src/caster"

# connect our proxy to the SCPR stream
(proxy = new ProxyRoom url:"http://206.221.211.12:80/").connect()

cast = new Caster 
    source:     proxy
    port:       8080