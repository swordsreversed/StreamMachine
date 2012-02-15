StreamMachine = require("./src/streammachine/core")

core = new StreamMachine
    listen:     8000
    streams:
        kpcclive:
            source: type:"proxy", url:"http://206.221.211.12:80/", metaTitle: "89.3 KPCC"
            rewind: seconds:(60*60*4)   # 4 hour buffer
            name: "89.3 KPCC - Southern California Public Radio"
            
        thecurrent:
            source: type:"proxy", url:"http://currentstream1.publicradio.org:80/", metaTitle: "The Current" 
            rewind: seconds:(60*30)     # 30 minute buffer
            name: "The Current"
                       
    
console.log "Core is connected."