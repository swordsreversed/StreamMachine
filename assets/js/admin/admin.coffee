class streammachine.Admin
    constructor: ->
        console.log "Admin init"
        
        # construct our socket
        @sock = io.connect("http://localhost:8015")