package StreamMachine {
    import flash.display.Sprite; 
    import flash.events.TimerEvent; 
    import flash.utils.Timer;
    
    import flash.media.SoundTransform;
    import flash.media.SoundChannel;
        
    public class Fader extends Sprite {
        private var len:Number
        private var channel:SoundChannel
        private var steps:Number
        private var timer:Timer
        private var _ticks:Number = 0
        private var _sndTick:Number
        private var _end:Number
        
        public function Fader(channel,start,end,ms=1000,steps=10) {
            // compute ms per step
            var stepms = ms / steps
            
            // compute sound change per step
            this._sndTick = (end - start) / steps
            this._end = end
            
            this.channel = channel
            
            var tform = this.channel.soundTransform || new SoundTransform(0,0)
            tform.volume = start
            this.channel.soundTransform = tform
                        
            this.timer = new Timer(stepms,steps);
            
            this.timer.addEventListener(TimerEvent.TIMER, this.onTick)
            this.timer.addEventListener(TimerEvent.TIMER_COMPLETE, this.onComplete)
            
            this.timer.start()
        }
        
        //----------
        
        private function onTick(e:TimerEvent):void {
            var tform = this.channel.soundTransform
            tform.volume = tform.volume + this._sndTick
            this.channel.soundTransform = tform
        }
        
        //----------
        
        private function onComplete(e:TimerEvent):void {
            // make sure we end up at our end volume
            var tform = this.channel.soundTransform
            tform.volume = this._end
            this.channel.soundTransform = tform
        }
    }
}