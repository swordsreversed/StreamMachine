# StreamMachine

A spare-time experiment in audio streaming, with an eye toward our aging 
shoutcast daemons.

## Currently

__test.coffee__ brings together two ideas: __ProxyRoom__ and __Caster__. 

ProxyRoom simply connects to KPCC's live stream, passes it to 
[node-icecast-stack](https://github.com/TooTallNate/node-icecast-stack), and 
then proxies through "data" and "metadata" events.

Caster supports several different options for passing that audio data on 
to listeners. 

The most interesting of those is __RewindBuffer__.  It creates a buffer for 
X amount of audio and works in concert with __RewindBuffer.Listener__ to allow 
listeners to connect to an arbitrary point in that buffer. This allows 
listeners to rewind live radio and stream from that point forward.

## Who?

You can blame Eric Richardson <erichardson@scpr.org>.