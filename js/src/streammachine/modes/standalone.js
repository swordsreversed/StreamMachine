var Logger, Master, Slave, StandaloneMode, express, nconf, _,
  __hasProp = {}.hasOwnProperty,
  __extends = function(child, parent) { for (var key in parent) { if (__hasProp.call(parent, key)) child[key] = parent[key]; } function ctor() { this.constructor = child; } ctor.prototype = parent.prototype; child.prototype = new ctor(); child.__super__ = parent.prototype; return child; };

_ = require("underscore");

express = require("express");

nconf = require("nconf");

Logger = require("../logger");

Master = require("../master");

Slave = require("../slave");

module.exports = StandaloneMode = (function(_super) {
  __extends(StandaloneMode, _super);

  StandaloneMode.prototype.MODE = "StandAlone";

  function StandaloneMode(opts, cb) {
    this.opts = opts;
    this.log = (new Logger(this.opts.log)).child({
      pid: process.pid
    });
    this.log.debug("StreamMachine standalone initialized.");
    process.title = "StreamMachine";
    StandaloneMode.__super__.constructor.apply(this, arguments);
    this.streams = {};
    this.master = new Master(_.extend({}, this.opts, {
      logger: this.log.child({
        mode: "master"
      })
    }));
    this.slave = new Slave(_.extend({}, this.opts, {
      logger: this.log.child({
        mode: "slave"
      })
    }));
    this.server = express();
    this.server.use("/api", this.master.api.app);
    this.server.use(this.slave.server.app);
    if (nconf.get("handoff")) {
      this._acceptHandoff();
    } else {
      this.log.info("Attaching listeners.");
      this.master.sourcein.listen();
      this.handle = this.server.listen(this.opts.port);
    }
    this.master.on("streams", (function(_this) {
      return function(streams) {
        _this.slave.once("streams", function() {
          var k, v, _results;
          _results = [];
          for (k in streams) {
            v = streams[k];
            _this.log.debug("looking to attach stream " + k, {
              streams: _this.streams[k] != null,
              slave_streams: _this.slave.streams[k] != null
            });
            if (_this.streams[k]) {

            } else {
              if (_this.slave.streams[k] != null) {
                _this.log.debug("mapping master -> slave on " + k);
                _this.slave.streams[k].useSource(v);
                _results.push(_this.streams[k] = true);
              } else {
                _results.push(_this.log.error("Unable to map master -> slave for " + k));
              }
            }
          }
          return _results;
        });
        return _this.slave.configureStreams(_this.master.config().streams);
      };
    })(this));
    this.log.debug("Standalone is listening on port " + this.opts.port);
    if (typeof cb === "function") {
      cb(null, this);
    }
  }

  StandaloneMode.prototype._sendHandoff = function(translator) {
    return this.master.sendHandoffData(translator, (function(_this) {
      return function(err) {
        _this.log.event("Sent master data to new process.");
        _this.log.info("Hand off standalone socket.");
        translator.send("standalone_socket", {}, _this.handle);
        return translator.once("standalone_socket_up", function() {
          _this.log.info("Got standalone socket confirmation. Closing listener.");
          _this.handle.unref();
          _this.log.info("Hand off source socket.");
          translator.send("source_socket", {}, _this.master.sourcein.server);
          return translator.once("source_socket_up", function() {
            _this.log.info("Got source socket confirmation. Closing listener.");
            _this.master.sourcein.server.unref();
            return _this.slave.sendHandoffData(translator, function(err) {
              _this.log.event("Sent slave data to new process. Exiting.");
              return process.exit();
            });
          });
        });
      };
    })(this));
  };

  StandaloneMode.prototype._acceptHandoff = function() {
    var translator;
    this.log.info("Initializing handoff receptor.");
    if (process.send == null) {
      this.log.error("Handoff called, but process has no send function. Aborting.");
      return false;
    }
    console.log("Sending GO");
    process.send("HANDOFF_GO");
    translator = new StandaloneMode.HandoffTranslator(process);
    return this.master.once("streams", (function(_this) {
      return function() {
        console.log("Sending STREAMS");
        translator.send("streams");
        _this.master.loadHandoffData(translator);
        _this.slave.loadHandoffData(translator);
        translator.once("standalone_socket", function(msg, handle) {
          _this.log.info("Got standalone socket.");
          _this.handle = _this.server.listen(handle);
          _this.log.info("Listening!");
          return translator.send("standalone_socket_up");
        });
        return translator.once("source_socket", function(msg, handle) {
          _this.log.info("Got source socket.");
          _this.master.sourcein.listen(handle);
          _this.log.info("Listening for sources!");
          return translator.send("source_socket_up");
        });
      };
    })(this));
  };

  return StandaloneMode;

})(require("./base"));

//# sourceMappingURL=standalone.js.map
