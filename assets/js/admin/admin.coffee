class streammachine.Admin
    constructor: ->
        console.log "Admin init"
        
        # construct our socket
        @sock = io.connect("http://localhost:8015/ADMIN")
        
        @sock.on "welcome", (opts) =>
            console.log "got welcome with ", opts
        
        