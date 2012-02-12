# StreamMachine

A spare-time experiment in audio streaming, with an eye toward our aging 
shoutcast daemons.

## Currently

__streamer.coffee__ connects to KPCC's live stream and MPR's The Current 
and serves them up at http://localhost:8000/kpcclive.mp3 and 
http://localhost:8000/thecurrent.mp3.

Four outputs are currently supported:

* If the client first connects a backchannel via socket.io and then passes 
?sock=xxxxx to the stream, we return a stream that is bound to the socket 
connection, allowing the socket to pass offset messages and seek through 
our __RewindBuffer__ while listening to one continuous stream.

* If there is an ?off=x parameter (like ?off=30), we return a 
__Core.RewindBuffer.Listener__ stream that is x seconds behind the live 
broadcast.

* If the player passes the icy-metadata header, we return a Shoutcast-compatible 
stream that includes regular metadata through __Core.Caster.Shoutcast__.

* If not, we return a raw mp3 stream through __Core.Caster.LiveMP3__.

## In the future?

Look for a demo of the seek-friendly web UI to be checked in shortly.

AAC support (including live transcoding from an MP3 input) would be nice, and is 
on the todo list.

A smarter shell script with a configuration file and support for command line 
arguments would be good.

Logging support needs to be written.

Generally everything needs to be beaten about and tested for edge cases that 
could cause it to crash.

## Who?

You can blame Eric Richardson <erichardson@scpr.org>.