package StreamMachine {
    import flash.display.MovieClip;
    import flash.display.LoaderInfo;
    import flash.media.Sound; 
    import flash.media.SoundLoaderContext; 
    import flash.media.SoundChannel;
    import flash.media.SoundTransform;
    import flash.net.URLRequest;
    
    import flash.external.*;
    
    public class Stream extends MovieClip {
        public var snd:Sound
        public var req:URLRequest
        public var ctx:SoundLoaderContext
        public var channel:SoundChannel
        
        public var paused:Boolean = false
        public var pausedAt:Number
        
        public function Stream() {
            var params = LoaderInfo(this.root.loaderInfo).parameters
            
            this.snd = new Sound();  
            
            this.req = new URLRequest(params.stream);
            this.ctx = new SoundLoaderContext(1000,false);
            
            this.snd.load(req,ctx)
            
            ExternalInterface.addCallback("play",this.sndplay)
            ExternalInterface.addCallback("pause",this.sndpause)
            ExternalInterface.addCallback("stop",this.sndstop)
            ExternalInterface.addCallback("seekToEnd",this.seekToEnd)
            ExternalInterface.addCallback("getBufferedTime",this.getBufferedTime)
            
            if ( params.JSInitFunc )
				ExternalInterface.call(params.JSInitFunc)
        }
        
     
        //----------
        
        public function sndplay():Boolean {
            if (this.channel) {
                // we're already playing
                return false;                
            } else {
                // create a channel by calling play()
                this.channel = this.snd.play()
                return true;
            }
        }
        
        //----------
        
        public function sndpause():Boolean {
            if (this.channel) {
                // playing...
                // stash the current time and then kill the channel
                this.pausedAt = this.channel.position
                this.paused = true
                this.channel.stop()
                
                return true
            } else {
                // not playing...
                
                // are we paused?
                if (this.paused && this.pausedAt) {
                    // yes...  we'll start playing again at the pause point
                    this.channel = this.snd.play(this.pausedAt)
                    
                    this.paused = false
                    this.pausedAt = 0
                    
                    return true
                } else {
                    return false
                }
            }
        }
        
        //----------
        
        public function sndstop():Boolean {
            if (this.channel) {
                this.channel.stop()
                this.snd.close()
                
                this.channel = null;
                
                return true;
            } else {
                // must not be playing...
                return false;
            }
        }
        
        //----------
                
        public function seekToEnd():Boolean {
            if (this.channel) {
                // playing... kill current channel
                this.channel.stop()
            }
            
            this.channel = this.snd.play( this.snd.length )
            new Fader(this.channel,0,1)
            
            return true;
        }
        
        //----------
        
        public function getBufferedTime():Number {
            if (this.channel) {
                return this.snd.length - this.channel.position                
            } else {
                return this.snd.length
            }
        }
        
    }
}