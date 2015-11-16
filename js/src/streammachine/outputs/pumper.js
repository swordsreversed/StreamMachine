var Pumper;

module.exports = Pumper = (function() {
  function Pumper(stream, opts) {
    this.stream = stream;
    this.opts = opts;
    Pumper.__super__.constructor.call(this, "pumper");
    this.stream.listen(this, {
      offsetSecs: this.req.param("from") || this.req.param("pump"),
      pump: this.req.param("pump"),
      pumpOnly: true
    }, (function(_this) {
      return function(err, playHead) {
        var headers;
        if (err) {
          _this.opts.res.status(500).end(err);
          return false;
        }
        headers = {
          "Content-Type": _this.stream.opts.format === "mp3" ? "audio/mpeg" : _this.stream.opts.format === "aac" ? "audio/aacp" : "unknown",
          "Connection": "close",
          "Content-Length": info.length
        };
        _this.res.writeHead(200, headers);
        playHead.pipe(_this.res);
        _this.opts.res.on("finish", function() {
          return playHead.disconnect();
        });
        _this.res.on("close", function() {
          return playHead.disconnect();
        });
        return _this.res.on("end", function() {
          return playHead.disconnect();
        });
      };
    })(this));
  }

  return Pumper;

})();

//# sourceMappingURL=pumper.js.map
