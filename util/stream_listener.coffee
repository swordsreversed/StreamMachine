StreamListener = require "../src/streammachine/util/stream_listener"

argv = require("optimist")
    .usage("Usage: $0 --host localhost --port 8001 --stream foo --shoutcast")
    .describe
        host:       "Server"
        port:       "Port"
        stream:     "Stream Key"
        shoutcast:  "Include 'icy-metaint' header?"
    .default
        shoutcast:  false
    .demand("host","port","stream")
    .argv

listener = new StreamListener argv.host, argv.port, argv.stream, argv.shoutcast

listener.connect (err) =>
    if err
        console.error "ERROR: #{err}"
        process.exit(1)

    else
        console.error "Connected."

setInterval =>
    console.error "#{listener.bytesReceived} bytes."
, 5000

process.on "SIGINT", =>
    console.error "Disconnecting..."
    listener.disconnect =>
        console.error "Disconnected. #{listener.bytesReceived} total bytes."
        process.exit()